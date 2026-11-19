/* Host diagnostic for missing codec parameters; not linked into the application. */
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <stdio.h>

int main(int argc, char **argv)
{
    if (argc != 2) return 64;
    AVFormatContext *input = NULL;
    int rc = avformat_open_input(&input, argv[1], NULL, NULL);
    if (rc < 0) return 1;
    rc = avformat_find_stream_info(input, NULL);
    printf("find_result=%d\n", rc);
    for (unsigned i = 0; i < input->nb_streams; ++i) {
        AVStream *stream = input->streams[i];
        AVCodecParserContext *parser = av_stream_get_parser(stream);
        printf("stream=%u codec=%s width=%d height=%d extradata=%d parser=%d parserWidth=%d parserHeight=%d parserFormat=%d\n",
               i, avcodec_get_name(stream->codecpar->codec_id), stream->codecpar->width, stream->codecpar->height,
               stream->codecpar->extradata_size, parser != NULL, parser ? parser->width : -1,
               parser ? parser->height : -1, parser ? parser->format : -1);
    }
    AVStream *stream = input->streams[0];
    AVCodecParserContext *parser = av_parser_init(stream->codecpar->codec_id);
    AVCodecContext *codec = avcodec_alloc_context3(NULL);
    AVPacket *packet = av_packet_alloc();
    if (parser && codec && packet) {
        avcodec_parameters_to_context(codec, stream->codecpar);
        parser->flags |= PARSER_FLAG_COMPLETE_FRAMES;
        for (int i = 0; i < 5 && av_read_frame(input, packet) >= 0; ++i) {
            if (packet->stream_index == 0) {
                uint8_t *parsed = NULL;
                int bytes = 0;
                int consumed = av_parser_parse2(parser, codec, &parsed, &bytes, packet->data, packet->size,
                                                packet->pts, packet->dts, packet->pos);
                printf("independentParser consumed=%d packet=%d width=%d height=%d format=%d\n",
                       consumed, packet->size, parser->width, parser->height, parser->format);
                if (parser->width > 0 && parser->height > 0) break;
            }
            av_packet_unref(packet);
        }
    }
    av_packet_free(&packet);
    avcodec_free_context(&codec);
    if (parser) av_parser_close(parser);
    avformat_close_input(&input);
    return 0;
}
