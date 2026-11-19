// SPDX-License-Identifier: GPL-2.0-or-later
#include "MediaProcessor.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/audio_fifo.h>
#include <libavutil/channel_layout.h>
#include <libavutil/crc.h>
#include <libavutil/error.h>
#include <libavutil/imgutils.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>
#include <lame/lame.h>
}

#include <algorithm>
#include <cerrno>
#include <climits>
#include <cstring>
#include <fcntl.h>
#include <limits>
#include <new>
#include <sys/stat.h>
#include <unistd.h>
#include <utility>

#ifndef XDM_MEDIA_ABI
#define XDM_MEDIA_ABI "host-test"
#endif

namespace xdm::media {
namespace {

constexpr int kIoBufferBytes = 64 * 1024;
constexpr int kMaxPacketBytes = 32 * 1024 * 1024;
constexpr int kMaxStreams = 64;
constexpr int kMaxAudioChannels = 64;
constexpr int kMaxFrameSamples = 262144;
constexpr int kMaxFifoSamples = 524288;
constexpr size_t kMaxHeaderPackets = 256;
constexpr size_t kMaxHeaderBytes = 8U * 1024U * 1024U;
constexpr int64_t kMaxSafeInteger = 9007199254740991LL;
constexpr AVRational kMilliseconds { 1, 1000 };

struct Failure {
    ErrorCode code;
    int nativeCode;
    Phase phase;
};

[[noreturn]] void Fail(ErrorCode code, int nativeCode, Phase phase)
{
    if (nativeCode == AVERROR(ENOMEM)) { code = ErrorCode::ResourceLimit; }
    throw Failure { code, nativeCode, phase };
}

void Check(int rc, ErrorCode code, Phase phase)
{
    if (rc < 0) { Fail(code, rc, phase); }
}

void CheckCancelled(JobState& job, Phase phase)
{
    job.phase.store(phase);
    if (job.IsCancelled()) { Fail(ErrorCode::Cancelled, AVERROR_EXIT, phase); }
}

int Interrupt(void* opaque)
{
    return static_cast<JobState*>(opaque)->IsCancelled() ? 1 : 0;
}

void Initialize()
{
    static std::once_flag initialized;
    std::call_once(initialized, [] {
        // The bundled FFmpeg symbols are hidden from other modules. Raw filenames,
        // metadata and decoder diagnostics must not leak into application logs.
        av_log_set_level(AV_LOG_QUIET);
        av_max_alloc(64U * 1024U * 1024U);
    });
}

int64_t TimeMs(int64_t value, AVRational timeBase)
{
    if (value == AV_NOPTS_VALUE || timeBase.num <= 0 || timeBase.den <= 0) { return -1; }
    int64_t result = av_rescale_q(value, timeBase, kMilliseconds);
    return result >= 0 && result <= kMaxSafeInteger ? result : -1;
}

int64_t SubtractTimestamp(int64_t value, int64_t offset)
{
    if (value == AV_NOPTS_VALUE) { return value; }
    if ((offset > 0 && value < INT64_MIN + offset) ||
        (offset < 0 && value > INT64_MAX + offset)) {
        Fail(ErrorCode::InvalidData, AVERROR_INVALIDDATA, Phase::Mux);
    }
    return value - offset;
}

struct PacketDeleter { void operator()(AVPacket* p) const { av_packet_free(&p); } };
struct FrameDeleter { void operator()(AVFrame* p) const { av_frame_free(&p); } };
struct CodecDeleter { void operator()(AVCodecContext* p) const { avcodec_free_context(&p); } };
struct ParserDeleter { void operator()(AVCodecParserContext* p) const { av_parser_close(p); } };
using Packet = std::unique_ptr<AVPacket, PacketDeleter>;
using Frame = std::unique_ptr<AVFrame, FrameDeleter>;
using Codec = std::unique_ptr<AVCodecContext, CodecDeleter>;
using Parser = std::unique_ptr<AVCodecParserContext, ParserDeleter>;

int StatDescriptor(int fd, struct stat* information)
{
    int rc;
    do { rc = fstat(fd, information); } while (rc < 0 && errno == EINTR);
    return rc;
}

int StatPath(const char* path, struct stat* information)
{
    int rc;
    do { rc = lstat(path, information); } while (rc < 0 && errno == EINTR);
    return rc;
}

Packet NewPacket()
{
    Packet packet(av_packet_alloc());
    if (!packet) { Fail(ErrorCode::ResourceLimit, AVERROR(ENOMEM), Phase::Open); }
    return packet;
}

Frame NewFrame()
{
    Frame frame(av_frame_alloc());
    if (!frame) { Fail(ErrorCode::ResourceLimit, AVERROR(ENOMEM), Phase::Decode); }
    return frame;
}

Codec NewCodec(const AVCodec* codec)
{
    Codec context(avcodec_alloc_context3(codec));
    if (!context) { Fail(ErrorCode::ResourceLimit, AVERROR(ENOMEM), Phase::Open); }
    return context;
}

uint16_t Big16(const uint8_t* bytes)
{
    return static_cast<uint16_t>((static_cast<uint16_t>(bytes[0]) << 8) | bytes[1]);
}

uint32_t Big32(const uint8_t* bytes)
{
    return (static_cast<uint32_t>(bytes[0]) << 24) | (static_cast<uint32_t>(bytes[1]) << 16) |
           (static_cast<uint32_t>(bytes[2]) << 8) | bytes[3];
}

bool CoverSize(uint32_t width, uint32_t height)
{
    // Bound header dimensions before integer conversion or muxer size arithmetic.
    return width > 0 && height > 0 && width <= 32768 && height <= 32768 &&
           static_cast<uint64_t>(width) * height <= 64U * 1024U * 1024U &&
           av_image_check_size(width, height, 0, nullptr) >= 0;
}

bool PngDimensions(const uint8_t* data, size_t size, int& width, int& height, JobState& job)
{
    static const uint8_t signature[] { 137, 80, 78, 71, 13, 10, 26, 10 };
    if (size < 8 || std::memcmp(data, signature, sizeof(signature)) != 0) { return false; }
    bool header = false;
    bool palette = false;
    bool dataStarted = false;
    bool dataEnded = false;
    size_t imageBytes = 0;
    uint8_t color = 0;
    size_t offset = 8;
    while (size - offset >= 12) {
        CheckCancelled(job, Phase::Open);
        size_t length = Big32(data + offset);
        if (length > size - offset - 12) { return false; }
        uint32_t type = Big32(data + offset + 4);
        for (size_t i = 0; i < 4; ++i) {
            uint8_t letter = data[offset + 4 + i];
            if (!((letter >= 'A' && letter <= 'Z') || (letter >= 'a' && letter <= 'z'))) { return false; }
        }
        if ((data[offset + 6] & 0x20) != 0) { return false; } // Reserved chunk-name bit.
        if (!header && type != 0x49484452U) { return false; } // IHDR must be first.
        uint32_t crc = UINT32_MAX;
        for (size_t read = 0; read < length + 4;) {
            CheckCancelled(job, Phase::Open);
            size_t count = std::min(length + 4 - read, static_cast<size_t>(kIoBufferBytes));
            crc = av_crc(av_crc_get_table(AV_CRC_32_IEEE_LE), crc, data + offset + 4 + read, count);
            read += count;
        }
        if (~crc != Big32(data + offset + 8 + length)) { return false; }
        if (type == 0x49484452U) {
            if (header || length != 13) { return false; }
            uint32_t w = Big32(data + offset + 8);
            uint32_t h = Big32(data + offset + 12);
            uint8_t depth = data[offset + 16];
            color = data[offset + 17];
            bool validDepth = (color == 0 && (depth == 1 || depth == 2 || depth == 4 || depth == 8 || depth == 16)) ||
                              (color == 3 && (depth == 1 || depth == 2 || depth == 4 || depth == 8)) ||
                              ((color == 2 || color == 4 || color == 6) && (depth == 8 || depth == 16));
            if (!CoverSize(w, h) || !validDepth || data[offset + 18] != 0 || data[offset + 19] != 0 ||
                data[offset + 20] > 1) { return false; }
            width = static_cast<int>(w);
            height = static_cast<int>(h);
            header = true;
        } else if (type == 0x504C5445U) { // PLTE
            if (palette || dataStarted || length == 0 || length > 768 || length % 3 != 0 ||
                color == 0 || color == 4) { return false; }
            palette = true;
        } else if (type == 0x49444154U) { // IDAT
            if (dataEnded || (color == 3 && !palette)) { return false; }
            dataStarted = true;
            imageBytes += length;
        } else if (type == 0x49454E44U) { // IEND
            return length == 0 && imageBytes > 0 && offset + 12 == size;
        } else {
            if ((data[offset + 4] & 0x20) == 0) { return false; } // Unknown critical chunk.
            if (dataStarted) { dataEnded = true; }
        }
        offset += length + 12;
    }
    return false;
}

bool JpegDimensions(const uint8_t* data, size_t size, int& width, int& height, JobState& job)
{
    if (size < 4 || data[0] != 0xFF || data[1] != 0xD8) { return false; }
    bool frame = false;
    bool scanned = false;
    bool entropyBytes = false;
    bool entropy = false;
    unsigned components = 0;
    size_t offset = 2;
    while (offset < size) {
        CheckCancelled(job, Phase::Open);
        if (entropy) {
            while (offset < size && data[offset] != 0xFF) {
                entropyBytes = true;
                if ((offset & 65535U) == 0) { CheckCancelled(job, Phase::Open); }
                ++offset;
            }
        }
        if (offset >= size || data[offset++] != 0xFF) { return false; }
        while (offset < size && data[offset] == 0xFF) {
            if ((offset & 65535U) == 0) { CheckCancelled(job, Phase::Open); }
            ++offset;
        }
        if (offset == size) { return false; }
        uint8_t marker = data[offset++];
        if (entropy && marker == 0) { entropyBytes = true; continue; }
        if (entropy && marker >= 0xD0 && marker <= 0xD7) { continue; }
        if (marker == 0xD9) { return frame && scanned && entropyBytes && offset == size; }
        if (marker == 0 || marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD7)) { return false; }
        entropy = false;
        if (marker == 0x01) { continue; } // Standalone TEM marker.
        if (size - offset < 2) { return false; }
        size_t length = Big16(data + offset);
        if (length < 2 || length > size - offset) { return false; }
        bool isFrame = marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC;
        if (isFrame) {
            if (frame || length < 8) { return false; }
            uint32_t h = Big16(data + offset + 3);
            uint32_t w = Big16(data + offset + 5);
            components = data[offset + 7];
            if (!CoverSize(w, h) || data[offset + 2] == 0 || data[offset + 2] > 16 ||
                components == 0 || components > 4 || length != 8 + 3 * components) { return false; }
            width = static_cast<int>(w);
            height = static_cast<int>(h);
            frame = true;
        } else if (marker == 0xDA) { // Multiple scans are valid for progressive JPEG.
            if (!frame || length < 6 || data[offset + 2] == 0 || data[offset + 2] > components ||
                length != 6U + 2U * data[offset + 2]) { return false; }
            entropy = true;
            scanned = true;
        }
        offset += length;
    }
    return false;
}

bool CoverParameters(const AVStream* stream, JobState& job)
{
    const AVPacket& picture = stream->attached_pic;
    if (!picture.data || picture.size <= 0 || picture.size > kMaxPacketBytes) { return false; }
    int width = 0;
    int height = 0;
    bool parsed = stream->codecpar->codec_id == AV_CODEC_ID_PNG ?
        PngDimensions(picture.data, static_cast<size_t>(picture.size), width, height, job) :
        JpegDimensions(picture.data, static_cast<size_t>(picture.size), width, height, job);
    if (!parsed) { return false; }
    // These are encoded-image header dimensions, not evidence of pixel decoding.
    stream->codecpar->width = width;
    stream->codecpar->height = height;
    return true;
}

// Open the file ourselves and give FFmpeg an AVIOContext, so FFmpeg never reopens
// a validated path, selects a network protocol, or truncates an existing output.
class FileIo final {
public:
    explicit FileIo(JobState& job) : job_(job) {}
    FileIo(const FileIo&) = delete;
    FileIo& operator=(const FileIo&) = delete;

    ~FileIo()
    {
        if (context_) {
            av_freep(&context_->buffer);
            avio_context_free(&context_);
        }
        if (fd_ >= 0) { close(fd_); }
        if (created_ && !keep_) {
            struct stat current {};
            // A replaced path does not belong to this job, even after an IO failure.
            if (StatPath(path_.c_str(), &current) == 0 && S_ISREG(current.st_mode) &&
                current.st_dev == identity_.st_dev && current.st_ino == identity_.st_ino) {
                unlink(path_.c_str());
            }
        }
    }

    void OpenInput(const std::string& path)
    {
        path_ = path;
        // O_NONBLOCK prevents a malicious/replaced FIFO from blocking before fstat.
        fd_ = open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NONBLOCK);
        if (fd_ < 0) {
            int error = errno;
            Fail(error == ENOENT || error == ENOTDIR ? ErrorCode::InputNotFound : ErrorCode::InputIo,
                 AVERROR(error), Phase::Open);
        }
        if (StatDescriptor(fd_, &identity_) != 0) { Fail(ErrorCode::InputIo, AVERROR(errno), Phase::Open); }
        if (!S_ISREG(identity_.st_mode)) { Fail(ErrorCode::InvalidArgument, AVERROR(EINVAL), Phase::Open); }
        if (identity_.st_size <= 0) { Fail(ErrorCode::InvalidData, AVERROR_INVALIDDATA, Phase::Open); }
        AllocateContext(false);
    }

    void OpenOutput(const std::string& path)
    {
        path_ = path;
        fd_ = open(path.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
        if (fd_ < 0) {
            int error = errno;
            Fail(error == EEXIST ? ErrorCode::OutputExists : ErrorCode::OutputIo,
                 AVERROR(error), Phase::Open);
        }
        if (StatDescriptor(fd_, &identity_) != 0) { Fail(ErrorCode::OutputIo, AVERROR(errno), Phase::Open); }
        created_ = true;
        AllocateContext(true);
    }

    AVIOContext* Context() const { return context_; }

    int64_t SyncAndClose()
    {
        CheckCancelled(job_, Phase::Close);
        avio_flush(context_);
        Check(context_->error, ErrorCode::OutputIo, Phase::Close);
        struct stat finalStat {};
        if (StatDescriptor(fd_, &finalStat) != 0) { Fail(ErrorCode::OutputIo, AVERROR(errno), Phase::Close); }
        if (!S_ISREG(finalStat.st_mode) || finalStat.st_size <= 0) {
            Fail(ErrorCode::InvalidData, AVERROR_INVALIDDATA, Phase::Close);
        }
        if (finalStat.st_size > kMaxSafeInteger) {
            Fail(ErrorCode::ResourceLimit, AVERROR(EFBIG), Phase::Close);
        }
        int rc;
        do { rc = fsync(fd_); } while (rc < 0 && errno == EINTR && !job_.IsCancelled());
        if (rc != 0) { Fail(ErrorCode::OutputIo, AVERROR(errno), Phase::Close); }
        CheckCancelled(job_, Phase::Close);
        int descriptor = fd_;
        fd_ = -1;
        // Do not retry close after EINTR: that descriptor may already be reused.
        if (close(descriptor) != 0) { Fail(ErrorCode::OutputIo, AVERROR(errno), Phase::Close); }
        struct stat pathStat {};
        if (StatPath(path_.c_str(), &pathStat) != 0) { Fail(ErrorCode::OutputIo, AVERROR(errno), Phase::Close); }
        if (!S_ISREG(pathStat.st_mode) || pathStat.st_dev != identity_.st_dev ||
            pathStat.st_ino != identity_.st_ino || pathStat.st_size != finalStat.st_size) {
            Fail(ErrorCode::OutputIo, AVERROR(ESTALE), Phase::Close);
        }
        // The returned pathname must still name the file we closed. An external
        // rename/unlink/replacement during processing cannot become a success.
        if (!job_.TryCommit()) { Fail(ErrorCode::Cancelled, AVERROR_EXIT, Phase::Close); }
        keep_ = true;
        return finalStat.st_size;
    }

private:
    void AllocateContext(bool writing)
    {
        auto* buffer = static_cast<uint8_t*>(av_malloc(kIoBufferBytes));
        if (!buffer) { Fail(ErrorCode::ResourceLimit, AVERROR(ENOMEM), Phase::Open); }
        context_ = avio_alloc_context(buffer, kIoBufferBytes, writing ? 1 : 0, this,
                                      writing ? nullptr : Read, writing ? Write : nullptr, Seek);
        if (!context_) {
            av_free(buffer);
            Fail(ErrorCode::ResourceLimit, AVERROR(ENOMEM), Phase::Open);
        }
        context_->seekable = AVIO_SEEKABLE_NORMAL;
    }

    static int Read(void* opaque, uint8_t* buffer, int bytes)
    {
        auto& file = *static_cast<FileIo*>(opaque);
        while (true) {
            if (file.job_.IsCancelled()) { return AVERROR_EXIT; }
            ssize_t count = read(file.fd_, buffer, static_cast<size_t>(bytes));
            if (count > 0) { return static_cast<int>(count); }
            if (count == 0) { return AVERROR_EOF; }
            if (errno != EINTR) { return AVERROR(errno); }
        }
    }

    static int Write(void* opaque, uint8_t* buffer, int bytes)
    {
        auto& file = *static_cast<FileIo*>(opaque);
        int written = 0;
        while (written < bytes) {
            if (file.job_.IsCancelled()) { return AVERROR_EXIT; }
            ssize_t count = write(file.fd_, buffer + written, static_cast<size_t>(bytes - written));
            if (count > 0) { written += static_cast<int>(count); }
            else if (count == 0) { return AVERROR(EIO); }
            else if (errno != EINTR) { return AVERROR(errno); }
        }
        return written;
    }

    static int64_t Seek(void* opaque, int64_t offset, int whence)
    {
        auto& file = *static_cast<FileIo*>(opaque);
        if (file.job_.IsCancelled()) { return AVERROR_EXIT; }
        whence &= ~AVSEEK_FORCE;
        if (whence == AVSEEK_SIZE) {
            struct stat information {};
            return StatDescriptor(file.fd_, &information) == 0 ? information.st_size : AVERROR(errno);
        }
        if (whence != SEEK_SET && whence != SEEK_CUR && whence != SEEK_END) { return AVERROR(EINVAL); }
        off_t result = lseek(file.fd_, static_cast<off_t>(offset), whence);
        return result >= 0 ? static_cast<int64_t>(result) : AVERROR(errno);
    }

    JobState& job_;
    int fd_ = -1;
    AVIOContext* context_ = nullptr;
    std::string path_;
    struct stat identity_ {};
    bool created_ = false;
    bool keep_ = false;
};

class Input final {
public:
    explicit Input(JobState& job) : io_(job), job_(job) {}
    ~Input() { if (context_) { avformat_close_input(&context_); } }

    void Open(const std::string& path)
    {
        CheckCancelled(job_, Phase::Open);
        io_.OpenInput(path);
        context_ = avformat_alloc_context();
        if (!context_) { Fail(ErrorCode::ResourceLimit, AVERROR(ENOMEM), Phase::Open); }
        context_->pb = io_.Context();
        context_->flags |= AVFMT_FLAG_CUSTOM_IO;
        context_->interrupt_callback = AVIOInterruptCB { Interrupt, &job_ };
        context_->max_streams = kMaxStreams;
        context_->probesize = 8 * 1024 * 1024;
        context_->max_analyze_duration = 10 * AV_TIME_BASE;
        context_->max_index_size = 4 * 1024 * 1024;
        context_->max_picture_buffer = kMaxPacketBytes;
        Check(avformat_open_input(&context_, path.c_str(), nullptr, nullptr), ErrorCode::InvalidData, Phase::Open);
        CheckCancelled(job_, Phase::Open);
        Check(avformat_find_stream_info(context_, nullptr), ErrorCode::InvalidData, Phase::Open);
        if (context_->nb_streams == 0 || context_->nb_streams > kMaxStreams) {
            Fail(ErrorCode::UnsupportedStream, AVERROR_INVALIDDATA, Phase::Open);
        }
    }

    bool ReadPacket(AVPacket* packet)
    {
        CheckCancelled(job_, Phase::Read);
        av_packet_unref(packet);
        if (bufferedIndex_ < buffered_.size()) {
            av_packet_move_ref(packet, buffered_[bufferedIndex_++].get());
            if (bufferedIndex_ == buffered_.size()) { buffered_.clear(); bufferedIndex_ = 0; }
            return true;
        }
        return ReadDemuxPacket(packet);
    }

    void PrepareRemux(Result& result)
    {
        // A parser-only FFmpeg build can finish stream probing with no dimensions
        // for TS H264/HEVC, and EOF probing can already have destroyed its parser.
        // Parse bounded initial access units using the public API, keeping every
        // original packet for remux. No decoder or invented dimensions are needed.
        std::vector<Parser> parsers(context_->nb_streams);
        std::vector<Codec> codecs(context_->nb_streams);
        unsigned missing = 0;
        for (unsigned i = 0; i < context_->nb_streams; ++i) {
            AVStream* stream = context_->streams[i];
            AVCodecParameters* parameters = stream->codecpar;
            if ((stream->disposition & AV_DISPOSITION_ATTACHED_PIC) &&
                (parameters->codec_id == AV_CODEC_ID_PNG || parameters->codec_id == AV_CODEC_ID_MJPEG)) {
                if (!CoverParameters(stream, job_)) {
                    result.warnings.emplace_back("INVALID_COVER_ART");
                    Fail(ErrorCode::UnsupportedStream, AVERROR_INVALIDDATA, Phase::Open);
                }
            }
            if (parameters->codec_type != AVMEDIA_TYPE_VIDEO ||
                (parameters->width > 0 && parameters->height > 0) ||
                (parameters->codec_id != AV_CODEC_ID_H264 && parameters->codec_id != AV_CODEC_ID_HEVC)) {
                continue;
            }
            parsers[i].reset(av_parser_init(parameters->codec_id));
            if (!parsers[i]) { Fail(ErrorCode::CodecUnavailable, AVERROR_DECODER_NOT_FOUND, Phase::Open); }
            codecs[i] = NewCodec(nullptr);
            Check(avcodec_parameters_to_context(codecs[i].get(), parameters), ErrorCode::InvalidData, Phase::Open);
            codecs[i]->pkt_timebase = context_->streams[i]->time_base;
            parsers[i]->flags |= PARSER_FLAG_COMPLETE_FRAMES;
            ++missing;
        }
        size_t bytes = 0;
        while (missing > 0) {
            CheckCancelled(job_, Phase::Open);
            if (buffered_.size() >= kMaxHeaderPackets) {
                Fail(ErrorCode::ResourceLimit, AVERROR(ENOBUFS), Phase::Open);
            }
            Packet packet = NewPacket();
            if (!ReadDemuxPacket(packet.get())) {
                Fail(ErrorCode::UnsupportedStream, AVERROR_INVALIDDATA, Phase::Open);
            }
            size_t packetBytes = static_cast<size_t>(packet->size);
            for (int i = 0; i < packet->side_data_elems; ++i) {
                if (packet->side_data[i].size > kMaxHeaderBytes - std::min(packetBytes, kMaxHeaderBytes)) {
                    Fail(ErrorCode::ResourceLimit, AVERROR(ENOBUFS), Phase::Open);
                }
                packetBytes += packet->side_data[i].size;
            }
            if (packetBytes > kMaxHeaderBytes - bytes) {
                Fail(ErrorCode::ResourceLimit, AVERROR(ENOBUFS), Phase::Open);
            }
            bytes += packetBytes;
            unsigned index = static_cast<unsigned>(packet->stream_index);
            if (parsers[index]) {
                AVCodecParserContext* parser = parsers[index].get();
                AVCodecContext* codec = codecs[index].get();
                uint8_t* parsedData = nullptr;
                int parsedBytes = 0;
                Check(av_parser_parse2(parser, codec, &parsedData, &parsedBytes, packet->data, packet->size,
                                       packet->pts, packet->dts, packet->pos), ErrorCode::InvalidData, Phase::Open);
                if (parser->width > 0 && parser->height > 0) {
                    AVCodecParameters* parameters = context_->streams[index]->codecpar;
                    if (parameters->width <= 0) { parameters->width = parser->width; }
                    if (parameters->height <= 0) { parameters->height = parser->height; }
                    if (parameters->format < 0) { parameters->format = parser->format; }
                    if (parameters->profile == FF_PROFILE_UNKNOWN) { parameters->profile = codec->profile; }
                    if (parameters->level == FF_LEVEL_UNKNOWN) { parameters->level = codec->level; }
                    parsers[index].reset();
                    codecs[index].reset();
                    --missing;
                }
            }
            buffered_.push_back(std::move(packet));
        }
    }

private:
    bool ReadDemuxPacket(AVPacket* packet)
    {
        CheckCancelled(job_, Phase::Read);
        int rc = av_read_frame(context_, packet);
        CheckCancelled(job_, Phase::Read);
        if (rc == AVERROR_EOF) { return false; }
        Check(rc, ErrorCode::InvalidData, Phase::Read);
        if (packet->size < 0 || packet->size > kMaxPacketBytes ||
            packet->stream_index < 0 || static_cast<unsigned>(packet->stream_index) >= context_->nb_streams) {
            Fail(ErrorCode::ResourceLimit, AVERROR_INVALIDDATA, Phase::Read);
        }
        return true;
    }

public:
    int64_t StartOffset(AVRational timeBase) const
    {
        return context_->start_time == AV_NOPTS_VALUE ? 0 :
               av_rescale_q(context_->start_time, AV_TIME_BASE_Q, timeBase);
    }

    int64_t PacketTime(const AVPacket* packet) const
    {
        const AVStream* stream = context_->streams[packet->stream_index];
        int64_t value = packet->dts != AV_NOPTS_VALUE ? packet->dts : packet->pts;
        if (value == AV_NOPTS_VALUE) { return value; }
        return av_rescale_q(SubtractTimestamp(value, StartOffset(stream->time_base)),
                            stream->time_base, AV_TIME_BASE_Q);
    }

    AVFormatContext* Context() const { return context_; }
    int64_t DurationMs() const { return TimeMs(context_->duration, AV_TIME_BASE_Q); }

private:
    FileIo io_;
    JobState& job_;
    AVFormatContext* context_ = nullptr;
    std::vector<Packet> buffered_;
    size_t bufferedIndex_ = 0;
};

class Output final {
public:
    explicit Output(JobState& job) : io_(job), job_(job) {}
    ~Output() { if (context_) { avformat_free_context(context_); } }

    void Open(const std::string& path, const std::string& container)
    {
        CheckCancelled(job_, Phase::Open);
        Check(avformat_alloc_output_context2(&context_, nullptr, container.c_str(), nullptr),
              ErrorCode::CodecUnavailable, Phase::Open);
        if (!context_) { Fail(ErrorCode::CodecUnavailable, AVERROR_MUXER_NOT_FOUND, Phase::Open); }
        io_.OpenOutput(path);
        context_->pb = io_.Context();
        context_->flags |= AVFMT_FLAG_CUSTOM_IO | AVFMT_FLAG_AUTO_BSF;
        context_->interrupt_callback = AVIOInterruptCB { Interrupt, &job_ };
        // Sparse streams cannot make the interleaver accumulate the whole input.
        context_->max_interleave_delta = AV_TIME_BASE;
    }

    AVFormatContext* Context() const { return context_; }

    void Header()
    {
        CheckCancelled(job_, Phase::Mux);
        int rc = avformat_write_header(context_, nullptr);
        Check(context_->pb->error, ErrorCode::OutputIo, Phase::Mux);
        Check(rc, ErrorCode::UnsupportedStream, Phase::Mux);
    }

    void Write(AVPacket* packet)
    {
        CheckCancelled(job_, Phase::Mux);
        int rc = av_interleaved_write_frame(context_, packet);
        if (context_->pb->error < 0) { Fail(ErrorCode::OutputIo, context_->pb->error, Phase::Mux); }
        Check(rc, ErrorCode::InvalidData, Phase::Mux);
    }

    int64_t Finish()
    {
        CheckCancelled(job_, Phase::Close);
        int rc = av_write_trailer(context_);
        if (context_->pb->error < 0) { Fail(ErrorCode::OutputIo, context_->pb->error, Phase::Close); }
        Check(rc, ErrorCode::InvalidData, Phase::Close);
        return io_.SyncAndClose();
    }

private:
    FileIo io_;
    JobState& job_;
    AVFormatContext* context_ = nullptr;
};

void CopyStreamProperties(AVStream* target, const AVStream* source)
{
    Check(avcodec_parameters_copy(target->codecpar, source->codecpar), ErrorCode::ResourceLimit, Phase::Open);
    target->codecpar->codec_tag = 0;
    target->time_base = source->time_base;
    target->avg_frame_rate = source->avg_frame_rate;
    target->sample_aspect_ratio = source->sample_aspect_ratio;
    target->disposition = source->disposition;
    Check(av_dict_copy(&target->metadata, source->metadata, 0), ErrorCode::ResourceLimit, Phase::Open);
    for (int i = 0; i < source->nb_side_data; ++i) {
        const AVPacketSideData& item = source->side_data[i];
        if (item.size > static_cast<size_t>(kMaxPacketBytes)) {
            Fail(ErrorCode::ResourceLimit, AVERROR(ENOMEM), Phase::Open);
        }
        uint8_t* destination = av_stream_new_side_data(target, item.type, item.size);
        if (!destination) { Fail(ErrorCode::ResourceLimit, AVERROR(ENOMEM), Phase::Open); }
        std::memcpy(destination, item.data, item.size);
    }
}

void AddRemuxStreams(Output& output, Input& input)
{
    for (unsigned i = 0; i < input.Context()->nb_streams; ++i) {
        const AVStream* source = input.Context()->streams[i];
        int supported = avformat_query_codec(output.Context()->oformat, source->codecpar->codec_id,
                                             FF_COMPLIANCE_NORMAL);
        // Matroska's NORMAL query omits VFW/ACM codecs accepted by its header
        // writer. Permit only entries in that muxer's own public codec-tag table;
        // write_header remains authoritative, with no MP4 compatibility bypass.
        bool matroskaTag = std::strcmp(output.Context()->oformat->name, "matroska") == 0 &&
            av_codec_get_tag(output.Context()->oformat->codec_tag, source->codecpar->codec_id) != 0;
        if ((supported == 0 && !matroskaTag) || source->codecpar->codec_type == AVMEDIA_TYPE_UNKNOWN) {
            Fail(ErrorCode::UnsupportedStream, AVERROR(EINVAL), Phase::Open);
        }
        AVStream* target = avformat_new_stream(output.Context(), nullptr);
        if (!target) { Fail(ErrorCode::ResourceLimit, AVERROR(ENOMEM), Phase::Open); }
        CopyStreamProperties(target, source);
    }
}

void Remux(const Request& request, JobState& job, Result& result)
{
    Input video(job);
    Input audio(job);
    video.Open(request.inputVideo);
    audio.Open(request.inputAudio);
    video.PrepareRemux(result);
    audio.PrepareRemux(result);
    if (video.Context()->nb_streams + audio.Context()->nb_streams > kMaxStreams) {
        Fail(ErrorCode::ResourceLimit, AVERROR(ENOMEM), Phase::Open);
    }
    int64_t videoDuration = video.DurationMs();
    int64_t audioDuration = audio.DurationMs();
    job.totalTimeMs.store(videoDuration < 0 || audioDuration < 0 ? -1 : std::max(videoDuration, audioDuration));
    Output output(job);
    output.Open(request.temporaryOutput, request.container);
    Check(av_dict_copy(&output.Context()->metadata, video.Context()->metadata, 0), ErrorCode::ResourceLimit, Phase::Open);
    AddRemuxStreams(output, video);
    AddRemuxStreams(output, audio);
    if (video.Context()->nb_chapters != 0 || audio.Context()->nb_chapters != 0) {
        result.warnings.emplace_back("CHAPTERS_NOT_COPIED");
    }
    output.Header();

    Packet packets[2] { NewPacket(), NewPacket() };
    Input* inputs[2] { &video, &audio };
    int offsets[2] { 0, static_cast<int>(video.Context()->nb_streams) };
    bool pending[2] { video.ReadPacket(packets[0].get()), audio.ReadPacket(packets[1].get()) };
    uint64_t packetCounts[2] { 0, 0 };
    int turn = 0;
    int64_t lastTimeMs = -1;
    while (pending[0] || pending[1]) {
        CheckCancelled(job, Phase::Read);
        int index;
        if (!pending[0]) { index = 1; }
        else if (!pending[1]) { index = 0; }
        else {
            int64_t first = video.PacketTime(packets[0].get());
            int64_t second = audio.PacketTime(packets[1].get());
            // Unknown timestamps stay unknown. Alternate reads instead of inventing DTS.
            index = first == AV_NOPTS_VALUE || second == AV_NOPTS_VALUE ? turn : (first <= second ? 0 : 1);
        }
        turn = 1 - index;
        Input& input = *inputs[index];
        AVPacket* packet = packets[index].get();
        AVStream* source = input.Context()->streams[packet->stream_index];
        AVStream* target = output.Context()->streams[packet->stream_index + offsets[index]];
        int64_t start = input.StartOffset(source->time_base);
        packet->pts = SubtractTimestamp(packet->pts, start);
        packet->dts = SubtractTimestamp(packet->dts, start);
        int64_t time = packet->pts != AV_NOPTS_VALUE ? packet->pts : packet->dts;
        if (time != AV_NOPTS_VALUE && packet->duration > 0 && time <= INT64_MAX - packet->duration) {
            time += packet->duration;
        }
        int64_t timeMs = TimeMs(time, source->time_base);
        if (timeMs >= 0) { lastTimeMs = std::max(lastTimeMs, timeMs); job.AdvanceTime(timeMs); }
        av_packet_rescale_ts(packet, source->time_base, target->time_base);
        packet->stream_index = target->index;
        packet->pos = -1;
        output.Write(packet);
        ++packetCounts[index];
        pending[index] = input.ReadPacket(packet);
    }
    if (packetCounts[0] == 0 || packetCounts[1] == 0) {
        Fail(ErrorCode::InvalidData, AVERROR_INVALIDDATA, Phase::Read);
    }
    result.durationMs = lastTimeMs;
    result.outputBytes = output.Finish();
}

int SelectAudio(const AVFormatContext* input)
{
    // FFmpeg n6.0 fftools/ffmpeg_mux_init.c map_auto_audio, for a single input.
    // Default disposition participates in the within-file selection, then ties
    // retain the earlier stream. Stream zero alone is not an audio selection rule.
    int selected = -1;
    int64_t best = -1;
    for (unsigned i = 0; i < input->nb_streams; ++i) {
        const AVStream* stream = input->streams[i];
        if (stream->codecpar->codec_type != AVMEDIA_TYPE_AUDIO || stream->discard == AVDISCARD_ALL) { continue; }
        int64_t score = stream->codecpar->ch_layout.nb_channels +
            100000000LL * !!(stream->event_flags & AVSTREAM_EVENT_FLAG_NEW_PACKETS) +
            5000000LL * !!(stream->disposition & AV_DISPOSITION_DEFAULT);
        if (score > best) { best = score; selected = static_cast<int>(i); }
    }
    if (selected < 0) { Fail(ErrorCode::UnsupportedStream, AVERROR_STREAM_NOT_FOUND, Phase::Open); }
    return selected;
}

int ChooseSampleRate(const AVCodec* encoder, int inputRate)
{
    if (!encoder->supported_samplerates) { return inputRate; }
    int result = encoder->supported_samplerates[0];
    for (const int* rate = encoder->supported_samplerates; *rate != 0; ++rate) {
        if (std::abs(*rate - inputRate) < std::abs(result - inputRate)) { result = *rate; }
    }
    return result;
}

class Mp3Pipeline final {
public:
    Mp3Pipeline(Input& input, Output& output, JobState& job, Result& result, int audioIndex)
        : input_(input), output_(output), job_(job), result_(result), audioIndex_(audioIndex),
          decoded_(NewFrame()), encoded_(NewPacket()) {}

    ~Mp3Pipeline()
    {
        if (resampler_) { swr_free(&resampler_); }
        if (fifo_) { av_audio_fifo_free(fifo_); }
        av_channel_layout_uninit(&sourceLayout_);
    }

    void OpenDecoder()
    {
        const AVStream* stream = input_.Context()->streams[audioIndex_];
        const AVCodec* codec = avcodec_find_decoder(stream->codecpar->codec_id);
        if (!codec) { Fail(ErrorCode::CodecUnavailable, AVERROR_DECODER_NOT_FOUND, Phase::Open); }
        decoder_ = NewCodec(codec);
        Check(avcodec_parameters_to_context(decoder_.get(), stream->codecpar), ErrorCode::InvalidData, Phase::Open);
        decoder_->pkt_timebase = stream->time_base;
        decoder_->thread_count = 1;
        decoder_->err_recognition = AV_EF_EXPLODE;
        Check(avcodec_open2(decoder_.get(), codec, nullptr), ErrorCode::CodecUnavailable, Phase::Open);
    }

    void SendPacket(const AVPacket* packet)
    {
        while (true) {
            CheckCancelled(job_, Phase::Decode);
            int rc = avcodec_send_packet(decoder_.get(), packet);
            if (rc == AVERROR(EAGAIN)) {
                int received = 0;
                DrainDecoder(received);
                if (received == 0) { Fail(ErrorCode::Internal, rc, Phase::Decode); }
                continue;
            }
            Check(rc, ErrorCode::InvalidData, Phase::Decode);
            break;
        }
        int received = 0;
        bool ended = DrainDecoder(received);
        if (packet == nullptr && !ended) { Fail(ErrorCode::InvalidData, AVERROR_INVALIDDATA, Phase::Decode); }
    }

    void Finish()
    {
        SendPacket(nullptr);
        if (!encoder_) { Fail(ErrorCode::InvalidData, AVERROR_INVALIDDATA, Phase::Decode); }
        DrainResampler();
        EncodeAvailable(true);
        SendFrame(nullptr);
        if (samplesSent_ <= 0) { Fail(ErrorCode::InvalidData, AVERROR_INVALIDDATA, Phase::Encode); }
        result_.durationMs = TimeMs(samplesSent_, encoder_->time_base);
    }

private:
    bool DrainDecoder(int& received)
    {
        while (true) {
            CheckCancelled(job_, Phase::Decode);
            av_frame_unref(decoded_.get());
            int rc = avcodec_receive_frame(decoder_.get(), decoded_.get());
            if (rc == AVERROR(EAGAIN)) { return false; }
            if (rc == AVERROR_EOF) { return true; }
            Check(rc, ErrorCode::InvalidData, Phase::Decode);
            ++received;
            ConvertFrame(decoded_.get());
        }
    }

    void PrepareEncoder(const AVFrame* frame)
    {
        const AVCodec* codec = avcodec_find_encoder_by_name("libmp3lame");
        if (!codec || !codec->sample_fmts) { Fail(ErrorCode::CodecUnavailable, AVERROR_ENCODER_NOT_FOUND, Phase::Encode); }
        encoder_ = NewCodec(codec);
        encoder_->sample_rate = ChooseSampleRate(codec, frame->sample_rate);
        encoder_->sample_fmt = codec->sample_fmts[0];
        for (const AVSampleFormat* format = codec->sample_fmts; *format != AV_SAMPLE_FMT_NONE; ++format) {
            if (*format == frame->format) { encoder_->sample_fmt = *format; break; }
        }
        av_channel_layout_default(&encoder_->ch_layout, frame->ch_layout.nb_channels == 1 ? 1 : 2);
        encoder_->time_base = AVRational { 1, encoder_->sample_rate };
        encoder_->thread_count = 1;
        if (output_.Context()->oformat->flags & AVFMT_GLOBALHEADER) { encoder_->flags |= AV_CODEC_FLAG_GLOBAL_HEADER; }
        // No imposed VBR or bitrate: retain libmp3lame's defaults, as the original CLI does.
        Check(avcodec_open2(encoder_.get(), codec, nullptr), ErrorCode::CodecUnavailable, Phase::Encode);
        if (encoder_->frame_size <= 0 || encoder_->frame_size > kMaxFrameSamples) {
            Fail(ErrorCode::CodecUnavailable, AVERROR(EINVAL), Phase::Encode);
        }
        audioOutput_ = avformat_new_stream(output_.Context(), nullptr);
        if (!audioOutput_) { Fail(ErrorCode::ResourceLimit, AVERROR(ENOMEM), Phase::Encode); }
        audioOutput_->time_base = encoder_->time_base;
        Check(avcodec_parameters_from_context(audioOutput_->codecpar, encoder_.get()), ErrorCode::Internal, Phase::Encode);
        const AVStream* audioInput = input_.Context()->streams[audioIndex_];
        Check(av_dict_copy(&audioOutput_->metadata, audioInput->metadata, 0), ErrorCode::ResourceLimit, Phase::Open);
        audioOutput_->disposition = audioInput->disposition;
        Check(av_dict_copy(&output_.Context()->metadata, input_.Context()->metadata, 0), ErrorCode::ResourceLimit, Phase::Open);
        PrepareCover();
        output_.Header();
        WriteCover();
        fifo_ = av_audio_fifo_alloc(encoder_->sample_fmt, encoder_->ch_layout.nb_channels, encoder_->frame_size);
        if (!fifo_) { Fail(ErrorCode::ResourceLimit, AVERROR(ENOMEM), Phase::Encode); }
    }

    void PrepareCover()
    {
        int64_t best = -1;
        bool unsupported = false;
        bool invalid = false;
        for (unsigned i = 0; i < input_.Context()->nb_streams; ++i) {
            const AVStream* stream = input_.Context()->streams[i];
            if (!(stream->disposition & AV_DISPOSITION_ATTACHED_PIC) ||
                stream->codecpar->codec_type != AVMEDIA_TYPE_VIDEO) { continue; }
            if (stream->codecpar->codec_id != AV_CODEC_ID_PNG && stream->codecpar->codec_id != AV_CODEC_ID_MJPEG) {
                unsupported = true;
                continue;
            }
            if (!CoverParameters(stream, job_)) { invalid = true; continue; }
            int64_t score = static_cast<int64_t>(stream->codecpar->width) * stream->codecpar->height +
                100000000LL * !!(stream->event_flags & AVSTREAM_EVENT_FLAG_NEW_PACKETS) +
                5000000LL * !!(stream->disposition & AV_DISPOSITION_DEFAULT);
            if (score > best) { best = score; coverInput_ = stream; }
        }
        if (unsupported) { result_.warnings.emplace_back("UNSUPPORTED_COVER_ART"); }
        if (invalid) { result_.warnings.emplace_back("INVALID_COVER_ART"); }
        if (!coverInput_) { return; }
        coverOutput_ = avformat_new_stream(output_.Context(), nullptr);
        if (!coverOutput_) { Fail(ErrorCode::ResourceLimit, AVERROR(ENOMEM), Phase::Open); }
        CopyStreamProperties(coverOutput_, coverInput_);
        coverOutput_->time_base = AVRational { 1, 1000 };
        // MP3 accepts PNG/JPEG APIC packets; retain their original pixels instead
        // of claiming that an unavailable image transcoder ran.
    }

    void WriteCover()
    {
        if (!coverInput_) { return; }
        Packet picture = NewPacket();
        Check(av_packet_ref(picture.get(), &coverInput_->attached_pic), ErrorCode::ResourceLimit, Phase::Mux);
        picture->stream_index = coverOutput_->index;
        picture->pts = 0;
        picture->dts = 0;
        picture->duration = 0;
        picture->pos = -1;
        output_.Write(picture.get());
    }

    void ConfigureResampler(const AVFrame* frame)
    {
        if (resampler_ && sourceRate_ == frame->sample_rate && sourceFormat_ == frame->format &&
            av_channel_layout_compare(&sourceLayout_, &frame->ch_layout) == 0) { return; }
        if (resampler_) { DrainResampler(); swr_free(&resampler_); }
        av_channel_layout_uninit(&sourceLayout_);
        Check(av_channel_layout_copy(&sourceLayout_, &frame->ch_layout), ErrorCode::ResourceLimit, Phase::Resample);
        if (sourceLayout_.order == AV_CHANNEL_ORDER_UNSPEC) {
            int channels = sourceLayout_.nb_channels;
            av_channel_layout_uninit(&sourceLayout_);
            av_channel_layout_default(&sourceLayout_, channels);
        }
        sourceRate_ = frame->sample_rate;
        sourceFormat_ = frame->format;
        Check(swr_alloc_set_opts2(&resampler_, &encoder_->ch_layout, encoder_->sample_fmt, encoder_->sample_rate,
                                  &sourceLayout_, static_cast<AVSampleFormat>(frame->format), frame->sample_rate,
                                  0, nullptr), ErrorCode::UnsupportedStream, Phase::Resample);
        Check(swr_init(resampler_), ErrorCode::UnsupportedStream, Phase::Resample);
    }

    Frame AudioFrame(int samples)
    {
        if (samples <= 0 || samples > kMaxFrameSamples) { Fail(ErrorCode::ResourceLimit, AVERROR(ENOMEM), Phase::Resample); }
        Frame result = NewFrame();
        result->format = encoder_->sample_fmt;
        result->sample_rate = encoder_->sample_rate;
        result->nb_samples = samples;
        Check(av_channel_layout_copy(&result->ch_layout, &encoder_->ch_layout), ErrorCode::ResourceLimit, Phase::Resample);
        Check(av_frame_get_buffer(result.get(), 0), ErrorCode::ResourceLimit, Phase::Resample);
        return result;
    }

    void ConvertFrame(const AVFrame* frame)
    {
        CheckCancelled(job_, Phase::Resample);
        if (frame->nb_samples < 0 || frame->nb_samples > kMaxFrameSamples ||
            frame->sample_rate <= 0 || frame->sample_rate > 768000 ||
            frame->ch_layout.nb_channels <= 0 || frame->ch_layout.nb_channels > kMaxAudioChannels ||
            !av_channel_layout_check(&frame->ch_layout)) {
            Fail(ErrorCode::UnsupportedStream, AVERROR_INVALIDDATA, Phase::Resample);
        }
        if (frame->nb_samples == 0) { return; }
        if (!encoder_) { PrepareEncoder(frame); }
        ConfigureResampler(frame);
        int capacity = swr_get_out_samples(resampler_, frame->nb_samples);
        Check(capacity, ErrorCode::InvalidData, Phase::Resample);
        Frame converted = AudioFrame(std::max(1, capacity));
        const uint8_t* planes[kMaxAudioChannels] {};
        int planeCount = av_sample_fmt_is_planar(static_cast<AVSampleFormat>(frame->format)) ? frame->ch_layout.nb_channels : 1;
        for (int i = 0; i < planeCount; ++i) { planes[i] = frame->extended_data[i]; }
        int samples = swr_convert(resampler_, converted->extended_data, capacity, planes, frame->nb_samples);
        Check(samples, ErrorCode::InvalidData, Phase::Resample);
        Append(converted.get(), samples);
    }

    void DrainResampler()
    {
        if (!resampler_) { return; }
        while (true) {
            CheckCancelled(job_, Phase::Resample);
            int capacity = swr_get_out_samples(resampler_, 0);
            Check(capacity, ErrorCode::InvalidData, Phase::Resample);
            capacity = std::max(4096, capacity);
            Frame converted = AudioFrame(capacity);
            int samples = swr_convert(resampler_, converted->extended_data, capacity, nullptr, 0);
            Check(samples, ErrorCode::InvalidData, Phase::Resample);
            if (samples == 0) { break; }
            Append(converted.get(), samples);
        }
    }

    void Append(AVFrame* frame, int samples)
    {
        if (samples == 0) { return; }
        CheckCancelled(job_, Phase::Resample);
        int existing = av_audio_fifo_size(fifo_);
        if (samples > kMaxFifoSamples - existing) { Fail(ErrorCode::ResourceLimit, AVERROR(ENOMEM), Phase::Resample); }
        Check(av_audio_fifo_realloc(fifo_, existing + samples), ErrorCode::ResourceLimit, Phase::Resample);
        int written = av_audio_fifo_write(fifo_, reinterpret_cast<void**>(frame->extended_data), samples);
        if (written != samples) { Fail(ErrorCode::Internal, AVERROR(EIO), Phase::Resample); }
        EncodeAvailable(false);
    }

    void EncodeAvailable(bool tail)
    {
        while (av_audio_fifo_size(fifo_) >= encoder_->frame_size || (tail && av_audio_fifo_size(fifo_) > 0)) {
            CheckCancelled(job_, Phase::Encode);
            int samples = std::min(av_audio_fifo_size(fifo_), encoder_->frame_size);
            if (samples < encoder_->frame_size && !(encoder_->codec->capabilities & AV_CODEC_CAP_SMALL_LAST_FRAME)) {
                Fail(ErrorCode::CodecUnavailable, AVERROR(EINVAL), Phase::Encode);
            }
            Frame frame = AudioFrame(samples);
            int readCount = av_audio_fifo_read(fifo_, reinterpret_cast<void**>(frame->extended_data), samples);
            if (readCount != samples) { Fail(ErrorCode::Internal, AVERROR(EIO), Phase::Encode); }
            frame->pts = samplesSent_;
            SendFrame(frame.get());
            if (samplesSent_ > INT64_MAX - samples) { Fail(ErrorCode::ResourceLimit, AVERROR(EFBIG), Phase::Encode); }
            samplesSent_ += samples;
            job_.AdvanceTime(TimeMs(samplesSent_, encoder_->time_base));
        }
    }

    void SendFrame(const AVFrame* frame)
    {
        while (true) {
            CheckCancelled(job_, Phase::Encode);
            int rc = avcodec_send_frame(encoder_.get(), frame);
            if (rc == AVERROR(EAGAIN)) {
                int received = 0;
                DrainEncoder(received);
                if (received == 0) { Fail(ErrorCode::Internal, rc, Phase::Encode); }
                continue;
            }
            Check(rc, ErrorCode::InvalidData, Phase::Encode);
            break;
        }
        int received = 0;
        bool ended = DrainEncoder(received);
        if (frame == nullptr && !ended) { Fail(ErrorCode::InvalidData, AVERROR_INVALIDDATA, Phase::Encode); }
    }

    bool DrainEncoder(int& received)
    {
        while (true) {
            CheckCancelled(job_, Phase::Encode);
            av_packet_unref(encoded_.get());
            int rc = avcodec_receive_packet(encoder_.get(), encoded_.get());
            if (rc == AVERROR(EAGAIN)) { return false; }
            if (rc == AVERROR_EOF) { return true; }
            Check(rc, ErrorCode::InvalidData, Phase::Encode);
            ++received;
            av_packet_rescale_ts(encoded_.get(), encoder_->time_base, audioOutput_->time_base);
            encoded_->stream_index = audioOutput_->index;
            encoded_->pos = -1;
            output_.Write(encoded_.get());
        }
    }

    Input& input_;
    Output& output_;
    JobState& job_;
    Result& result_;
    int audioIndex_;
    Frame decoded_;
    Packet encoded_;
    Codec decoder_;
    Codec encoder_;
    SwrContext* resampler_ = nullptr;
    AVAudioFifo* fifo_ = nullptr;
    AVChannelLayout sourceLayout_ {};
    int sourceRate_ = 0;
    int sourceFormat_ = AV_SAMPLE_FMT_NONE;
    int64_t samplesSent_ = 0;
    AVStream* audioOutput_ = nullptr;
    const AVStream* coverInput_ = nullptr;
    AVStream* coverOutput_ = nullptr;
};

void ToMp3(const Request& request, JobState& job, Result& result)
{
    Input input(job);
    input.Open(request.inputAudio);
    if (input.Context()->nb_chapters != 0) { result.warnings.emplace_back("CHAPTERS_NOT_COPIED"); }
    int audioIndex = SelectAudio(input.Context());
    const AVStream* source = input.Context()->streams[audioIndex];
    int64_t streamDuration = TimeMs(source->duration, source->time_base);
    job.totalTimeMs.store(streamDuration >= 0 ? streamDuration : input.DurationMs());
    Output output(job);
    output.Open(request.temporaryOutput, "mp3");
    Mp3Pipeline pipeline(input, output, job, result, audioIndex);
    pipeline.OpenDecoder();
    Packet packet = NewPacket();
    while (input.ReadPacket(packet.get())) {
        if (packet->stream_index == audioIndex) { pipeline.SendPacket(packet.get()); }
    }
    pipeline.Finish();
    result.outputBytes = output.Finish();
}

void Validate(const Request& request)
{
    if (!ValidJobId(request.jobId) || !ValidAbsolutePath(request.inputAudio) ||
        !ValidAbsolutePath(request.temporaryOutput) || request.temporaryOutput == request.inputAudio ||
        (request.operation == Operation::Remux &&
         (!ValidAbsolutePath(request.inputVideo) || request.temporaryOutput == request.inputVideo ||
          (request.container != "mp4" && request.container != "matroska")))) {
        Fail(ErrorCode::InvalidArgument, AVERROR(EINVAL), Phase::Validate);
    }
}

} // namespace

Capabilities GetCapabilities()
{
    Initialize();
    Capabilities result;
    result.ffmpegVersion = av_version_info();
    result.lameVersion = get_lame_version();
    result.abi = XDM_MEDIA_ABI;
    result.remuxMp4 = av_guess_format("mp4", nullptr, nullptr) != nullptr;
    result.remuxMatroska = av_guess_format("matroska", nullptr, nullptr) != nullptr;
    result.encodeMp3 = avcodec_find_encoder_by_name("libmp3lame") != nullptr &&
                       av_guess_format("mp3", nullptr, nullptr) != nullptr;
    return result;
}

Result Process(const Request& request, JobState& job) noexcept
{
    Result result;
    try {
        // Allocate all success result strings before the output's commit point.
        result.jobId = request.jobId;
        result.outputPath = request.temporaryOutput;
        result.format = request.operation == Operation::ToMp3 ? "mp3" : request.container;
        Initialize();
        CheckCancelled(job, Phase::Validate);
        Validate(request);
        if (request.operation == Operation::Remux) { Remux(request, job, result); }
        else { ToMp3(request, job, result); }
        result.status = Status::Success;
        result.errorCode = ErrorCode::None;
        result.nativeCode = 0;
        result.phase = Phase::Close;
        return result;
    } catch (const Failure& error) {
        result.errorCode = error.code;
        result.nativeCode = error.nativeCode;
        result.phase = error.phase;
    } catch (const std::bad_alloc&) {
        result.errorCode = ErrorCode::ResourceLimit;
        result.nativeCode = AVERROR(ENOMEM);
        result.phase = job.phase.load();
    } catch (...) {
        result.errorCode = ErrorCode::Internal;
        result.nativeCode = AVERROR_UNKNOWN;
        result.phase = job.phase.load();
    }
    job.FinishFailure();
    if (job.IsCancelled()) {
        result.status = Status::Cancelled;
        result.errorCode = ErrorCode::Cancelled;
        result.nativeCode = AVERROR_EXIT;
    } else { result.status = Status::Failed; }
    result.outputPath.clear();
    result.outputBytes = 0;
    result.durationMs = -1;
    return result;
}

} // namespace xdm::media
