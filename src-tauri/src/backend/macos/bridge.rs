use std::{
    net::UdpSocket,
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::{self, Receiver, Sender},
        Arc, Mutex,
    },
    thread::{self, JoinHandle},
    time::Duration,
};

use cpal::{
    traits::{DeviceTrait, HostTrait, StreamTrait},
    Device, FromSample, Sample, SampleFormat, SizedSample, Stream, StreamConfig, SupportedStreamConfigRange,
};
use crossbeam_queue::ArrayQueue;

const BRIDGE_BIND_ADDR: &str = "127.0.0.1:56901";
const DRIVER_SAMPLE_RATE: u32 = 44_100;
const DRIVER_CHANNELS: usize = 2;
const SAMPLE_QUEUE_CAPACITY: usize = DRIVER_SAMPLE_RATE as usize * DRIVER_CHANNELS * 4;

#[derive(Debug, Clone, Default)]
pub struct BridgeStatus {
    pub running: bool,
    pub target_device_id: Option<String>,
    pub target_device_name: Option<String>,
    pub last_error: Option<String>,
}

#[derive(Debug, Clone)]
pub struct BridgeTarget {
    pub device_id: String,
    pub device_name: String,
}

enum BridgeCommand {
    SetTarget(BridgeTarget),
    Shutdown,
}

struct SharedState {
    status: BridgeStatus,
}

pub struct MacosAudioBridge {
    state: Arc<Mutex<SharedState>>,
    running: Arc<AtomicBool>,
    command_sender: Sender<BridgeCommand>,
    receiver_thread: Option<JoinHandle<()>>,
    playback_thread: Option<JoinHandle<()>>,
}

impl MacosAudioBridge {
    pub fn start(initial_target: BridgeTarget) -> Result<Self, String> {
        let state = Arc::new(Mutex::new(SharedState {
            status: BridgeStatus::default(),
        }));
        let queue = Arc::new(ArrayQueue::<f32>::new(SAMPLE_QUEUE_CAPACITY));
        let running = Arc::new(AtomicBool::new(true));

        let socket = UdpSocket::bind(BRIDGE_BIND_ADDR)
            .map_err(|cause| format!("Waves audio bridge could not bind UDP socket: {cause}"))?;
        socket
            .set_nonblocking(true)
            .map_err(|cause| format!("Waves audio bridge could not switch UDP socket to nonblocking mode: {cause}"))?;

        let receiver_queue = Arc::clone(&queue);
        let receiver_state = Arc::clone(&state);
        let receiver_running = Arc::clone(&running);
        let receiver_thread =
            thread::spawn(move || udp_receiver_loop(socket, receiver_queue, receiver_state, receiver_running));

        let (command_sender, command_receiver) = mpsc::channel();
        let playback_queue = Arc::clone(&queue);
        let playback_state = Arc::clone(&state);
        let playback_running = Arc::clone(&running);
        let playback_thread = thread::spawn(move || {
            playback_loop(initial_target, command_receiver, playback_queue, playback_state, playback_running)
        });

        Ok(Self {
            state,
            running,
            command_sender,
            receiver_thread: Some(receiver_thread),
            playback_thread: Some(playback_thread),
        })
    }

    pub fn set_target(&self, target: BridgeTarget) -> Result<(), String> {
        self.command_sender
            .send(BridgeCommand::SetTarget(target))
            .map_err(|cause| format!("Waves audio bridge command dispatch failed: {cause}"))
    }

    pub fn status(&self) -> BridgeStatus {
        self.state
            .lock()
            .map(|state| state.status.clone())
            .unwrap_or_default()
    }
}

impl Drop for MacosAudioBridge {
    fn drop(&mut self) {
        self.running.store(false, Ordering::Relaxed);
        let _ = self.command_sender.send(BridgeCommand::Shutdown);
        if let Some(handle) = self.playback_thread.take() {
            let _ = handle.join();
        }
        if let Some(handle) = self.receiver_thread.take() {
            let _ = handle.join();
        }
    }
}

fn udp_receiver_loop(
    socket: UdpSocket,
    queue: Arc<ArrayQueue<f32>>,
    state: Arc<Mutex<SharedState>>,
    running: Arc<AtomicBool>,
) {
    let mut packet = [0_u8; 4096];
    while running.load(Ordering::Relaxed) {
        match socket.recv(&mut packet) {
            Ok(byte_count) => {
                for bytes in packet[..byte_count].chunks_exact(4) {
                    let sample = f32::from_ne_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
                    while queue.push(sample).is_err() {
                        let _ = queue.pop();
                    }
                }
            }
            Err(cause) if cause.kind() == std::io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(2));
            }
            Err(cause) => {
                update_error(&state, format!("Waves audio bridge UDP receive failed: {cause}"));
                thread::sleep(Duration::from_millis(50));
            }
        }
    }
}

fn playback_loop(
    initial_target: BridgeTarget,
    command_receiver: Receiver<BridgeCommand>,
    queue: Arc<ArrayQueue<f32>>,
    state: Arc<Mutex<SharedState>>,
    running: Arc<AtomicBool>,
) {
    let mut current_target = initial_target;
    let mut stream = match build_stream_for_target(&current_target, Arc::clone(&queue), Arc::clone(&state)) {
        Ok(stream) => Some(stream),
        Err(cause) => {
            update_error(&state, cause);
            None
        }
    };

    while running.load(Ordering::Relaxed) {
        match command_receiver.recv_timeout(Duration::from_millis(200)) {
            Ok(BridgeCommand::SetTarget(target)) => {
                current_target = target;
                stream = None;
                while queue.pop().is_some() {}
                match build_stream_for_target(&current_target, Arc::clone(&queue), Arc::clone(&state)) {
                    Ok(next_stream) => stream = Some(next_stream),
                    Err(cause) => update_error(&state, cause),
                }
            }
            Ok(BridgeCommand::Shutdown) => break,
            Err(mpsc::RecvTimeoutError::Timeout) => {
                if stream.is_none() {
                    match build_stream_for_target(&current_target, Arc::clone(&queue), Arc::clone(&state)) {
                        Ok(next_stream) => stream = Some(next_stream),
                        Err(cause) => update_error(&state, cause),
                    }
                }
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }

    update_status(&state, |status| {
        status.running = false;
    });
}

fn build_stream_for_target(
    target: &BridgeTarget,
    queue: Arc<ArrayQueue<f32>>,
    state: Arc<Mutex<SharedState>>,
) -> Result<Stream, String> {
    let host = cpal::default_host();
    let device = find_output_device(&host, &target.device_name)
        .or_else(|| host.default_output_device())
        .ok_or_else(|| "Waves audio bridge could not find a usable output device.".to_string())?;
    let config_range = pick_output_config(&device)?;
    let sample_format = config_range.sample_format();
    let config = config_range.with_sample_rate(DRIVER_SAMPLE_RATE).config();
    let channels = config.channels as usize;

    let stream = match sample_format {
        SampleFormat::F32 => {
            build_output_stream::<f32>(&device, &config, channels, Arc::clone(&queue), Arc::clone(&state))?
        }
        SampleFormat::I16 => {
            build_output_stream::<i16>(&device, &config, channels, Arc::clone(&queue), Arc::clone(&state))?
        }
        SampleFormat::U16 => {
            build_output_stream::<u16>(&device, &config, channels, Arc::clone(&queue), Arc::clone(&state))?
        }
        other => {
            return Err(format!(
                "Waves audio bridge found unsupported sample format for {}: {other:?}",
                target.device_name
            ))
        }
    };

    stream
        .play()
        .map_err(|cause| format!("Waves audio bridge could not start playback: {cause}"))?;

    update_status(&state, |status| {
        status.running = true;
        status.target_device_id = Some(target.device_id.clone());
        status.target_device_name = Some(target.device_name.clone());
        status.last_error = None;
    });

    Ok(stream)
}

fn find_output_device(host: &cpal::Host, device_name: &str) -> Option<Device> {
    let devices = host.output_devices().ok()?;
    for device in devices {
        if device
            .description()
            .ok()
            .map(|description| description.name().to_string())
            .as_deref()
            == Some(device_name)
        {
            return Some(device);
        }
    }

    None
}

fn pick_output_config(device: &Device) -> Result<SupportedStreamConfigRange, String> {
    let configs = device
        .supported_output_configs()
        .map_err(|cause| format!("Waves audio bridge could not inspect device formats: {cause}"))?;

    configs
        .filter(|config| {
            config.channels() >= DRIVER_CHANNELS as u16
                && config.min_sample_rate() <= DRIVER_SAMPLE_RATE
                && config.max_sample_rate() >= DRIVER_SAMPLE_RATE
        })
        .max_by_key(|config| config.channels())
        .ok_or_else(|| "Waves audio bridge could not find a matching 44.1kHz output format.".to_string())
}

fn build_output_stream<T>(
    device: &Device,
    config: &StreamConfig,
    channels: usize,
    queue: Arc<ArrayQueue<f32>>,
    state: Arc<Mutex<SharedState>>,
) -> Result<Stream, String>
where
    T: SizedSample + FromSample<f32>,
{
    device
        .build_output_stream(
            config,
            move |data: &mut [T], _| write_audio_data::<T>(data, channels, &queue),
            move |cause| update_error(&state, format!("Waves audio bridge stream error: {cause}")),
            None,
        )
        .map_err(|cause| format!("Waves audio bridge could not build output stream: {cause}"))
}

fn write_audio_data<T>(data: &mut [T], channel_count: usize, queue: &ArrayQueue<f32>)
where
    T: Sample + FromSample<f32>,
{
    for frame in data.chunks_mut(channel_count) {
        let left = queue.pop().unwrap_or(0.0);
        let right = queue.pop().unwrap_or(left);

        for (index, sample) in frame.iter_mut().enumerate() {
            let next = match index {
                0 => left,
                1 => right,
                _ => 0.0,
            };
            *sample = T::from_sample(next);
        }
    }
}

fn update_status(state: &Arc<Mutex<SharedState>>, mutator: impl FnOnce(&mut BridgeStatus)) {
    if let Ok(mut state) = state.lock() {
        mutator(&mut state.status);
    }
}

fn update_error(state: &Arc<Mutex<SharedState>>, message: String) {
    update_status(state, |status| {
        status.running = false;
        status.last_error = Some(message);
    });
}
