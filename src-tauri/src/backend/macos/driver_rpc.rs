use std::{
    io::{BufRead, BufReader, Write},
    net::{TcpStream, ToSocketAddrs},
    time::Duration,
};

const DRIVER_CONTROL_ADDR: &str = "127.0.0.1:56902";
const DRIVER_TIMEOUT_MS: u64 = 400;

#[derive(Debug, Clone)]
pub struct DriverSession {
    pub key: String,
    pub bundle_id: Option<String>,
    pub pid: i32,
    pub connected_clients: u32,
    pub volume: u8,
    pub muted: bool,
    pub peak: f32,
    pub last_seen_ms: u64,
    pub last_signal_ms: u64,
    pub recent_signal: bool,
    pub recent_render: bool,
}

#[derive(Debug, Clone)]
pub struct DriverSnapshot {
    pub generated_at_ms: u64,
    pub sessions: Vec<DriverSession>,
}

fn connect() -> Result<TcpStream, String> {
    let address = DRIVER_CONTROL_ADDR
        .to_socket_addrs()
        .map_err(|cause| format!("Waves driver address resolution failed: {cause}"))?
        .next()
        .ok_or_else(|| "Waves driver address resolution returned no addresses.".to_string())?;
    let stream = TcpStream::connect_timeout(&address, Duration::from_millis(DRIVER_TIMEOUT_MS))
        .map_err(|cause| format!("Waves driver connection failed: {cause}"))?;
    stream
        .set_read_timeout(Some(Duration::from_millis(DRIVER_TIMEOUT_MS)))
        .map_err(|cause| format!("Waves driver read timeout setup failed: {cause}"))?;
    stream
        .set_write_timeout(Some(Duration::from_millis(DRIVER_TIMEOUT_MS)))
        .map_err(|cause| format!("Waves driver write timeout setup failed: {cause}"))?;
    Ok(stream)
}

fn send_command(command: &str) -> Result<Vec<String>, String> {
    let mut stream = connect()?;
    stream
        .write_all(command.as_bytes())
        .and_then(|_| stream.write_all(b"\n"))
        .map_err(|cause| format!("Waves driver request failed: {cause}"))?;

    let mut lines = Vec::new();
    let mut reader = BufReader::new(stream);
    loop {
        let mut line = String::new();
        let count = reader
            .read_line(&mut line)
            .map_err(|cause| format!("Waves driver response failed: {cause}"))?;
        if count == 0 {
            break;
        }

        let trimmed = line.trim_end_matches(['\r', '\n']).to_string();
        if trimmed.is_empty() {
            break;
        }

        let done = trimmed == "END";
        lines.push(trimmed);
        if done {
            break;
        }
    }

    Ok(lines)
}

pub fn ping_driver() -> Result<(), String> {
    let response = send_command("PING")?;
    match response.first() {
        Some(line) if line.starts_with("OK\t") => Ok(()),
        Some(line) => Err(format!("Unexpected Waves driver ping response: {line}")),
        None => Err("Waves driver returned no ping response.".to_string()),
    }
}

pub fn snapshot() -> Result<DriverSnapshot, String> {
    let response = send_command("SNAPSHOT")?;
    let mut generated_at_ms = 0_u64;
    let mut sessions = Vec::new();

    for line in response {
        if line == "END" {
            break;
        }

        let parts = line.split('\t').collect::<Vec<_>>();
        match parts.first().copied() {
            Some("META") => {
                if let Some(value) = parts.get(2) {
                    generated_at_ms = value.parse::<u64>().unwrap_or(0);
                }
            }
            Some("SESSION") => {
                if parts.len() < 13 {
                    continue;
                }

                sessions.push(DriverSession {
                    key: parts[1].to_string(),
                    bundle_id: if parts[2].is_empty() {
                        None
                    } else {
                        Some(parts[2].to_string())
                    },
                    pid: parts[3].parse::<i32>().unwrap_or_default(),
                    connected_clients: parts[4].parse::<u32>().unwrap_or_default(),
                    volume: parts[5].parse::<u8>().unwrap_or(100),
                    muted: parts[6] == "1",
                    peak: parts[7].parse::<f32>().unwrap_or_default(),
                    last_seen_ms: parts[8].parse::<u64>().unwrap_or_default(),
                    last_signal_ms: parts[9].parse::<u64>().unwrap_or_default(),
                    recent_signal: parts[11] == "1",
                    recent_render: parts[12] == "1",
                });
            }
            _ => {}
        }
    }

    Ok(DriverSnapshot {
        generated_at_ms,
        sessions,
    })
}

pub fn set_volume(key: &str, volume: u8) -> Result<(), String> {
    let response = send_command(&format!("SET_VOLUME\t{key}\t{}", volume.min(100)))?;
    match response.first() {
        Some(line) if line == "OK" => Ok(()),
        Some(line) => Err(format!("Waves driver rejected volume update: {line}")),
        None => Err("Waves driver returned no response for volume update.".to_string()),
    }
}

pub fn set_mute(key: &str, muted: bool) -> Result<(), String> {
    let response = send_command(&format!("SET_MUTE\t{key}\t{}", if muted { 1 } else { 0 }))?;
    match response.first() {
        Some(line) if line == "OK" => Ok(()),
        Some(line) => Err(format!("Waves driver rejected mute update: {line}")),
        None => Err("Waves driver returned no response for mute update.".to_string()),
    }
}
