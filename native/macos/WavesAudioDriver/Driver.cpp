// Copyright (c) Jonathan Reed
// Licensed for use within Waves.

#include <aspl/Driver.hpp>
#include <aspl/Stream.hpp>

#include <CoreAudio/AudioServerPlugIn.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstring>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

namespace {

constexpr const char* kDriverName = "Waves";
constexpr const char* kDriverUID = "com.jonathanreed.waves.virtual-output";
constexpr const char* kDriverIdentifier = "com.jonathanreed.waves";
constexpr const char* kLoopbackAddress = "127.0.0.1";
constexpr UInt16 kAudioPort = 56901;
constexpr UInt16 kControlPort = 56902;
constexpr UInt32 kSampleRate = 44100;
constexpr UInt32 kChannelCount = 2;
constexpr UInt32 kPacketBytes = 4096;
constexpr float kSignalThreshold = 0.003f;
constexpr std::uint64_t kSessionRetainMs = 15000;
constexpr std::uint64_t kSignalRetainMs = 1800;

std::uint64_t now_millis()
{
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

std::uint32_t float_to_bits(float value)
{
    std::uint32_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    return bits;
}

float bits_to_float(std::uint32_t bits)
{
    float value = 0.0f;
    std::memcpy(&value, &bits, sizeof(value));
    return value;
}

bool starts_with(const std::string& value, const char* prefix)
{
    const auto length = std::strlen(prefix);
    return value.size() >= length && value.compare(0, length, prefix) == 0;
}

bool ends_with_ignore_case(const std::string& value, const std::string& suffix)
{
    if (value.size() < suffix.size()) {
        return false;
    }

    for (std::size_t i = 0; i < suffix.size(); ++i) {
        const auto left = static_cast<unsigned char>(value[value.size() - suffix.size() + i]);
        const auto right = static_cast<unsigned char>(suffix[i]);
        if (std::tolower(left) != std::tolower(right)) {
            return false;
        }
    }

    return true;
}

std::string canonical_bundle_id(const std::string& raw_bundle_id)
{
    if (raw_bundle_id.empty()) {
        return raw_bundle_id;
    }

    if (raw_bundle_id == "com.apple.WebKit.WebContent") {
        return "com.apple.Safari";
    }

    const auto helper_index = raw_bundle_id.rfind(".helper");
    if (helper_index != std::string::npos) {
        return raw_bundle_id.substr(0, helper_index);
    }

    return raw_bundle_id;
}

struct SharedSession
{
    explicit SharedSession(std::string session_key, std::string session_bundle_id, pid_t session_pid)
        : key(std::move(session_key))
        , bundle_id(std::move(session_bundle_id))
        , pid(session_pid)
    {
        const auto now = now_millis();
        last_seen_ms.store(now);
        last_render_ms.store(now);
    }

    const std::string key;
    const std::string bundle_id;
    const pid_t pid;

    std::atomic<std::uint32_t> volume_percent {100};
    std::atomic<bool> muted {false};
    std::atomic<std::uint32_t> peak_bits {0};
    std::atomic<std::uint64_t> last_seen_ms {0};
    std::atomic<std::uint64_t> last_signal_ms {0};
    std::atomic<std::uint64_t> last_render_ms {0};
    std::atomic<std::uint32_t> connected_clients {0};
};

class WavesClient final : public aspl::Client
{
public:
    WavesClient(const aspl::ClientInfo& client_info, std::shared_ptr<SharedSession> shared_session)
        : aspl::Client(client_info)
        , session_(std::move(shared_session))
    {
    }

    const std::shared_ptr<SharedSession>& session() const
    {
        return session_;
    }

private:
    std::shared_ptr<SharedSession> session_;
};

class WavesHandler final : public aspl::ControlRequestHandler, public aspl::IORequestHandler
{
public:
    WavesHandler()
    {
        setup_audio_socket();
        start_control_server();
    }

    ~WavesHandler() override
    {
        control_running_.store(false);

        if (control_socket_ != -1) {
            shutdown(control_socket_, SHUT_RDWR);
            close(control_socket_);
            control_socket_ = -1;
        }

        if (control_thread_.joinable()) {
            control_thread_.join();
        }

        if (audio_socket_ != -1) {
            close(audio_socket_);
            audio_socket_ = -1;
        }
    }

    std::shared_ptr<aspl::Client> OnAddClient(const aspl::ClientInfo& client_info) override
    {
        const auto bundle_id = canonical_bundle_id(client_info.BundleID);
        const auto key = bundle_id.empty()
            ? "pid-" + std::to_string(client_info.ProcessID)
            : bundle_id;

        std::lock_guard<std::mutex> lock(sessions_mutex_);
        auto& session_ref = sessions_[key];
        if (!session_ref) {
            session_ref = std::make_shared<SharedSession>(key, bundle_id, client_info.ProcessID);
        }

        session_ref->connected_clients.fetch_add(1);
        session_ref->last_seen_ms.store(now_millis());
        session_ref->last_render_ms.store(now_millis());

        return std::make_shared<WavesClient>(client_info, session_ref);
    }

    void OnRemoveClient(std::shared_ptr<aspl::Client> client) override
    {
        const auto waves_client = std::dynamic_pointer_cast<WavesClient>(client);
        if (!waves_client) {
            return;
        }

        const auto now = now_millis();
        auto session = waves_client->session();
        session->last_seen_ms.store(now);
        session->connected_clients.fetch_sub(1);
    }

    void OnProcessClientOutput(const std::shared_ptr<aspl::Client>& client,
        const std::shared_ptr<aspl::Stream>&,
        Float64,
        Float64,
        Float32* frames,
        UInt32 frame_count,
        UInt32 channel_count) override
    {
        const auto waves_client = std::dynamic_pointer_cast<WavesClient>(client);
        if (!waves_client || !frames) {
            return;
        }

        const auto session = waves_client->session();
        const auto now = now_millis();
        session->last_seen_ms.store(now);
        session->last_render_ms.store(now);

        const std::size_t sample_count = static_cast<std::size_t>(frame_count) * channel_count;
        float peak = 0.0f;
        for (std::size_t index = 0; index < sample_count; ++index) {
            peak = std::max(peak, std::fabs(frames[index]));
        }

        session->peak_bits.store(float_to_bits(peak));
        if (peak >= kSignalThreshold) {
            session->last_signal_ms.store(now);
        }

        const auto muted = session->muted.load();
        const auto gain = muted
            ? 0.0f
            : static_cast<float>(session->volume_percent.load()) / 100.0f;
        if (gain == 1.0f) {
            return;
        }

        for (std::size_t index = 0; index < sample_count; ++index) {
            frames[index] *= gain;
        }
    }

    void OnWriteMixedOutput(const std::shared_ptr<aspl::Stream>&,
        Float64,
        Float64,
        const void* bytes,
        UInt32 bytes_count) override
    {
        if (audio_socket_ == -1 || !bytes || bytes_count == 0) {
            return;
        }

        const auto* data = static_cast<const std::uint8_t*>(bytes);
        std::size_t remaining = bytes_count;

        while (remaining > 0) {
            const auto packet_size = static_cast<int>(std::min<std::size_t>(remaining, kPacketBytes));
            send(audio_socket_, data, packet_size, MSG_DONTWAIT);
            data += packet_size;
            remaining -= static_cast<std::size_t>(packet_size);
        }
    }

private:
    void setup_audio_socket()
    {
        audio_socket_ = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (audio_socket_ == -1) {
            return;
        }

        std::memset(&audio_address_, 0, sizeof(audio_address_));
        audio_address_.sin_family = AF_INET;
        audio_address_.sin_port = htons(kAudioPort);
        inet_pton(AF_INET, kLoopbackAddress, &audio_address_.sin_addr);
        connect(audio_socket_, reinterpret_cast<sockaddr*>(&audio_address_), sizeof(audio_address_));
    }

    void start_control_server()
    {
        control_socket_ = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (control_socket_ == -1) {
            return;
        }

        int enabled = 1;
        setsockopt(control_socket_, SOL_SOCKET, SO_REUSEADDR, &enabled, sizeof(enabled));

        sockaddr_in address {};
        address.sin_family = AF_INET;
        address.sin_port = htons(kControlPort);
        inet_pton(AF_INET, kLoopbackAddress, &address.sin_addr);

        if (bind(control_socket_, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) {
            close(control_socket_);
            control_socket_ = -1;
            return;
        }

        if (listen(control_socket_, 8) != 0) {
            close(control_socket_);
            control_socket_ = -1;
            return;
        }

        control_thread_ = std::thread([this]() { control_loop(); });
    }

    void control_loop()
    {
        while (control_running_.load()) {
            sockaddr_in peer {};
            socklen_t peer_length = sizeof(peer);
            const auto client_fd =
                accept(control_socket_, reinterpret_cast<sockaddr*>(&peer), &peer_length);

            if (client_fd < 0) {
                if (!control_running_.load()) {
                    break;
                }
                continue;
            }

            handle_control_client(client_fd);
            close(client_fd);
        }
    }

    void handle_control_client(int client_fd)
    {
        std::string request;
        char buffer[1024];
        while (true) {
            const auto count = recv(client_fd, buffer, sizeof(buffer), 0);
            if (count <= 0) {
                break;
            }

            request.append(buffer, buffer + count);
            if (request.find('\n') != std::string::npos) {
                break;
            }
        }

        const auto line_end = request.find('\n');
        if (line_end != std::string::npos) {
            request.erase(line_end);
        }

        const auto response = handle_command(request);
        send(client_fd, response.data(), response.size(), 0);
    }

    std::string handle_command(const std::string& request)
    {
        if (request == "PING") {
            return "OK\tWavesAudio\t0.1.0\n";
        }

        if (request == "SNAPSHOT") {
            return build_snapshot();
        }

        if (starts_with(request, "SET_VOLUME\t")) {
            return apply_volume_command(request.substr(std::strlen("SET_VOLUME\t")));
        }

        if (starts_with(request, "SET_MUTE\t")) {
            return apply_mute_command(request.substr(std::strlen("SET_MUTE\t")));
        }

        return "ERR\tunsupported-command\n";
    }

    std::string apply_volume_command(const std::string& payload)
    {
        const auto separator = payload.find('\t');
        if (separator == std::string::npos) {
            return "ERR\tinvalid-volume-command\n";
        }

        const auto key = payload.substr(0, separator);
        const auto raw_volume = payload.substr(separator + 1);
        const auto volume = std::clamp(std::stoi(raw_volume), 0, 100);

        std::lock_guard<std::mutex> lock(sessions_mutex_);
        const auto iterator = sessions_.find(key);
        if (iterator == sessions_.end()) {
            return "ERR\tunknown-session\n";
        }

        iterator->second->volume_percent.store(static_cast<std::uint32_t>(volume));
        iterator->second->muted.store(volume == 0);
        return "OK\n";
    }

    std::string apply_mute_command(const std::string& payload)
    {
        const auto separator = payload.find('\t');
        if (separator == std::string::npos) {
            return "ERR\tinvalid-mute-command\n";
        }

        const auto key = payload.substr(0, separator);
        const auto muted = payload.substr(separator + 1) == "1";

        std::lock_guard<std::mutex> lock(sessions_mutex_);
        const auto iterator = sessions_.find(key);
        if (iterator == sessions_.end()) {
            return "ERR\tunknown-session\n";
        }

        iterator->second->muted.store(muted);
        return "OK\n";
    }

    std::string build_snapshot()
    {
        const auto now = now_millis();
        std::lock_guard<std::mutex> lock(sessions_mutex_);

        prune_inactive_sessions(now);

        std::ostringstream response;
        response << "META\t" << kDriverUID << "\t" << now << "\n";

        for (const auto& [key, session] : sessions_) {
            const auto last_seen = session->last_seen_ms.load();
            const auto last_signal = session->last_signal_ms.load();
            const auto last_render = session->last_render_ms.load();
            const auto connected = session->connected_clients.load();
            const auto muted = session->muted.load() ? 1 : 0;
            const auto volume = session->volume_percent.load();
            const auto peak = bits_to_float(session->peak_bits.load());
            const auto recent_signal = last_signal > 0 && now - last_signal <= kSignalRetainMs ? 1 : 0;
            const auto recent_render = last_render > 0 && now - last_render <= kSignalRetainMs ? 1 : 0;

            response
                << "SESSION\t"
                << key << "\t"
                << session->bundle_id << "\t"
                << session->pid << "\t"
                << connected << "\t"
                << volume << "\t"
                << muted << "\t"
                << peak << "\t"
                << last_seen << "\t"
                << last_signal << "\t"
                << last_render << "\t"
                << recent_signal << "\t"
                << recent_render << "\n";
        }

        response << "END\n";
        return response.str();
    }

    void prune_inactive_sessions(std::uint64_t now)
    {
        for (auto iterator = sessions_.begin(); iterator != sessions_.end();) {
            const auto& session = iterator->second;
            const auto connected = session->connected_clients.load();
            const auto last_seen = session->last_seen_ms.load();
            if (connected == 0 && (last_seen == 0 || now - last_seen > kSessionRetainMs)) {
                iterator = sessions_.erase(iterator);
                continue;
            }

            ++iterator;
        }
    }

    int audio_socket_ {-1};
    sockaddr_in audio_address_ {};
    int control_socket_ {-1};
    std::atomic<bool> control_running_ {true};
    std::thread control_thread_;
    std::mutex sessions_mutex_;
    std::unordered_map<std::string, std::shared_ptr<SharedSession>> sessions_;
};

std::shared_ptr<aspl::Driver> create_driver()
{
    auto context = std::make_shared<aspl::Context>();

    aspl::DeviceParameters device_params;
    device_params.Name = kDriverName;
    device_params.Manufacturer = "Waves";
    device_params.DeviceUID = kDriverUID;
    device_params.ModelUID = "com.jonathanreed.waves.driver";
    device_params.ConfigurationApplicationBundleID = kDriverIdentifier;
    device_params.SampleRate = kSampleRate;
    device_params.ChannelCount = kChannelCount;
    device_params.EnableMixing = true;
    device_params.CanBeDefault = true;
    device_params.CanBeDefaultForSystemSounds = true;

    auto device = std::make_shared<aspl::Device>(context, device_params);

    aspl::StreamParameters stream_params;
    stream_params.Direction = aspl::Direction::Output;
    stream_params.Format = {
        .mSampleRate = kSampleRate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
        .mBitsPerChannel = 32,
        .mChannelsPerFrame = kChannelCount,
        .mBytesPerFrame = sizeof(Float32) * kChannelCount,
        .mFramesPerPacket = 1,
        .mBytesPerPacket = sizeof(Float32) * kChannelCount,
    };

    device->AddStreamWithControlsAsync(stream_params);

    auto handler = std::make_shared<WavesHandler>();
    device->SetControlHandler(handler);
    device->SetIOHandler(handler);

    auto plugin = std::make_shared<aspl::Plugin>(context);
    plugin->AddDevice(device);

    return std::make_shared<aspl::Driver>(context, plugin);
}

} // namespace

extern "C" void* WavesEntryPoint(CFAllocatorRef, CFUUIDRef type_uuid)
{
    if (!CFEqual(type_uuid, kAudioServerPlugInTypeUUID)) {
        return nullptr;
    }

    static std::shared_ptr<aspl::Driver> driver = create_driver();
    return driver->GetReference();
}
