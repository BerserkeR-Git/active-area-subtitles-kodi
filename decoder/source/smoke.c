/* Loads the built decoder library the way the add-on does (by full path, nothing linked), resolves every
 * function named in the exports file, then opens a film and decodes its first keyframe as ffmpeg.py does
 * (av_find_best_stream's decoder, one thread, key frames only), and reads the video stream's keyframe index as
 * ffmpeg.py does (a seek to the start first, which makes Matroska read its cues). Prints one JSON line: the size,
 * the rows of black bar at the top and bottom of the luma plane, the index's entries and the keyframes among them.
 * Exit 0 only when all of that worked.
 *
 *   smoke LIBRARY EXPORTS_FILE FILM
 *
 * Built for Linux (dlopen) and Windows (LoadLibrary, run under Wine); FFmpeg's headers give the structures only.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>

#ifdef _WIN32
#include <windows.h>
static void *open_library(const char *path) { return (void *) LoadLibraryA(path); }
static void *find(void *library, const char *name) { return (void *) GetProcAddress((HMODULE) library, name); }
#else
#include <dlfcn.h>
static void *open_library(const char *path) { return dlopen(path, RTLD_NOW | RTLD_LOCAL); }
static void *find(void *library, const char *name) { return dlsym(library, name); }
#endif

#define BIND(name) __typeof__(&name) p_##name = (__typeof__(&name)) need(library, #name)

static void *need(void *library, const char *name)
{
    void *symbol = find(library, name);
    if (!symbol) {
        fprintf(stderr, "missing function %s\n", name);
        exit(3);
    }
    return symbol;
}

static int dark(const uint8_t *row, int width, int ten_bit)
{
    long sum = 0;
    for (int x = 0; x < width; x++)
        sum += ten_bit ? ((const uint16_t *) row)[x] >> 2 : row[x];
    return sum / width < 32;
}

int main(int argc, char **argv)
{
    if (argc != 4) {
        fprintf(stderr, "usage: smoke LIBRARY EXPORTS_FILE FILM\n");
        return 2;
    }
    void *library = open_library(argv[1]);
    if (!library) {
        fprintf(stderr, "library would not load\n");
        return 3;
    }
    FILE *names = fopen(argv[2], "r");
    if (!names) {
        fprintf(stderr, "no exports file\n");
        return 2;
    }
    char name[128];
    int resolved = 0;
    while (fscanf(names, "%127s", name) == 1) {
        need(library, name);
        resolved++;
    }
    fclose(names);

    BIND(av_log_set_level);
    BIND(avformat_version);
    BIND(avformat_open_input);
    BIND(avformat_find_stream_info);
    BIND(av_find_best_stream);
    BIND(av_read_frame);
    BIND(avformat_close_input);
    BIND(avcodec_alloc_context3);
    BIND(avcodec_parameters_to_context);
    BIND(avcodec_open2);
    BIND(avcodec_send_packet);
    BIND(avcodec_receive_frame);
    BIND(avcodec_free_context);
    BIND(av_packet_alloc);
    BIND(av_packet_unref);
    BIND(av_packet_free);
    BIND(av_frame_alloc);
    BIND(av_frame_free);
    BIND(av_opt_set_int);
    BIND(av_get_pix_fmt_name);
    BIND(av_seek_frame);
    BIND(avformat_index_get_entries_count);
    BIND(avformat_index_get_entry);
    BIND(avformat_index_get_entry_from_timestamp);

    p_av_log_set_level(AV_LOG_QUIET);
    AVFormatContext *format = NULL;
    if (p_avformat_open_input(&format, argv[3], NULL, NULL) < 0 || p_avformat_find_stream_info(format, NULL) < 0) {
        fprintf(stderr, "film would not open\n");
        return 4;
    }
    const AVCodec *decoder = NULL;
    int index = p_av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1, &decoder, 0);
    if (index < 0 || !decoder) {
        fprintf(stderr, "no video stream with a decoder\n");
        return 4;
    }
    AVCodecContext *context = p_avcodec_alloc_context3(decoder);
    p_avcodec_parameters_to_context(context, format->streams[index]->codecpar);
    p_av_opt_set_int(context, "threads", 1, 0);
    p_av_opt_set_int(context, "skip_frame", AVDISCARD_NONKEY, 0);
    if (p_avcodec_open2(context, decoder, NULL) < 0) {
        fprintf(stderr, "decoder would not open\n");
        return 4;
    }
    AVPacket *packet = p_av_packet_alloc();
    AVFrame *frame = p_av_frame_alloc();
    int got = 0;
    for (int packets = 0; packets < 2000 && !got && p_av_read_frame(format, packet) >= 0; packets++) {
        if (packet->stream_index == index && p_avcodec_send_packet(context, packet) >= 0)
            got = p_avcodec_receive_frame(context, frame) >= 0;
        p_av_packet_unref(packet);
    }
    if (!got) {
        fprintf(stderr, "no frame decoded\n");
        return 5;
    }
    const char *format_name = p_av_get_pix_fmt_name(frame->format);
    int ten_bit = format_name && strstr(format_name, "10") != NULL;
    int top = 0, bottom = 0;
    while (top < frame->height && dark(frame->data[0] + (size_t) top * frame->linesize[0], frame->width, ten_bit))
        top++;
    while (bottom < frame->height - top &&
           dark(frame->data[0] + (size_t) (frame->height - 1 - bottom) * frame->linesize[0], frame->width, ten_bit))
        bottom++;
    /* The keyframe index: every keyframe entry from the first entry's time on, as ffmpeg.py walks it. */
    AVStream *stream = format->streams[index];
    p_av_seek_frame(format, -1, 0, AVSEEK_FLAG_BACKWARD);
    int entries = p_avformat_index_get_entries_count(stream), keyframes = 0;
    const AVIndexEntry *entry = entries > 0 ? p_avformat_index_get_entry(stream, 0) : NULL;
    for (int64_t wanted = entry ? entry->timestamp : 0; entry && keyframes < 200000; keyframes++) {
        entry = p_avformat_index_get_entry_from_timestamp(stream, wanted, 0);
        if (!entry || entry->timestamp == INT64_MAX)
            break;
        wanted = entry->timestamp + 1;
    }
    printf("{\"avformat\": %u, \"functions\": %d, \"decoder\": \"%s\", \"format\": \"%s\", \"width\": %d, "
           "\"height\": %d, \"top\": %d, \"bottom\": %d, \"index\": %d, \"keyframes\": %d}\n",
           p_avformat_version() >> 16, resolved, decoder->name, format_name ? format_name : "?", frame->width,
           frame->height, top, bottom, entries, keyframes);
    p_av_frame_free(&frame);
    p_av_packet_free(&packet);
    p_avcodec_free_context(&context);
    p_avformat_close_input(&format);
    return 0;
}
