#pragma once

#define VIRTUACAM_PROP_FRAME_EX 7u

#define VIRTUACAM_DRIVER_STATUS_VERSION 2u
#define VIRTUACAM_DRIVER_STATUS_V1_SIZE 112u

#define VIRTUACAM_FRAME_EX_VERSION 1u

enum VIRTUACAM_FRAME_FORMAT
{
    VIRTUACAM_FRAME_FORMAT_UNKNOWN = 0,
    VIRTUACAM_FRAME_FORMAT_BGR24 = 1,
    VIRTUACAM_FRAME_FORMAT_BGRA32 = 2,
    VIRTUACAM_FRAME_FORMAT_RGB32 = 3,
    VIRTUACAM_FRAME_FORMAT_NV12 = 4,
    VIRTUACAM_FRAME_FORMAT_YUY2 = 5
};

#define VIRTUACAM_UPLOAD_FORMAT_MASK_BGRA32 (1u << VIRTUACAM_FRAME_FORMAT_BGRA32)
#define VIRTUACAM_UPLOAD_FORMAT_MASK_RGB32  (1u << VIRTUACAM_FRAME_FORMAT_RGB32)
#define VIRTUACAM_UPLOAD_FORMAT_MASK_NV12   (1u << VIRTUACAM_FRAME_FORMAT_NV12)

typedef struct _VIRTUACAM_FRAME_EX_HEADER
{
    unsigned long Size;
    unsigned long Version;
    unsigned long Format;
    unsigned long Flags;
    unsigned long Width;
    unsigned long Height;
    long Stride0;
    long Stride1;
    unsigned long PayloadOffset;
    unsigned long PayloadLength;
    unsigned long long FrameId;
    unsigned long Reserved[4];
} VIRTUACAM_FRAME_EX_HEADER, *PVIRTUACAM_FRAME_EX_HEADER;

#ifdef __cplusplus
static_assert(sizeof(VIRTUACAM_FRAME_EX_HEADER) == 64, "FrameEx ABI header must stay 64 bytes.");
#endif
