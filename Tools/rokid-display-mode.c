// rokid-display-mode — read and set the Rokid Max display mode over USB.
//
//   serial        read the serial number (read-only channel test)
//   get           read the current display mode
//   set <0|1|3|4> change the display mode
//
//     0 = 2D (same image both eyes)     1 = stereo
//     3 = high refresh rate             4 = high refresh rate + side-by-side
//
// macOS binds the glasses' HID interface to Apple's AppleUserUSBHostHIDDevice,
// but these requests are device-recipient, so a device-level libusb open is
// enough — no interface claim, no kext, no root.
//
// Protocol per badicsalex/ar-drivers-rs. Note the two easy-to-miss details:
// wIndex is 0x1 (not 0), and the OUT request carries a 1-byte payload rather
// than a zero-length one. Getting either wrong makes the device silently time
// out rather than stall, which looks exactly like a permissions problem.
//
// Build:
//   clang -O2 -o .build/rokid-display-mode Tools/rokid-display-mode.c \
//     -I/opt/homebrew/opt/libusb/include/libusb-1.0 \
//     -L/opt/homebrew/opt/libusb/lib -lusb-1.0
//
// If the display ends up unreadable, unplug and replug the glasses.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libusb.h>

#define ROKID_VID 0x04D2
#define ROKID_PID 0x162F
#define TIMEOUT_MS 1000

static const char *mode_name(int m) {
    switch (m) {
        case 0: return "2D (same image both eyes)";
        case 1: return "stereo";
        case 2: return "half side-by-side";
        case 3: return "high refresh rate";
        case 4: return "high refresh rate + side-by-side";
        default: return "unknown";
    }
}

static uint8_t req_in(void) {
    return LIBUSB_ENDPOINT_IN | LIBUSB_REQUEST_TYPE_VENDOR | LIBUSB_RECIPIENT_DEVICE;
}
static uint8_t req_out(void) {
    return LIBUSB_ENDPOINT_OUT | LIBUSB_REQUEST_TYPE_VENDOR | LIBUSB_RECIPIENT_DEVICE;
}

static void usage(const char *prog) {
    fprintf(stderr, "usage: %s serial | get | set <0|1|3|4>\n", prog);
}

int main(int argc, char **argv) {
    if (argc < 2) { usage(argv[0]); return 2; }

    libusb_context *ctx = NULL;
    if (libusb_init(&ctx) != 0) {
        fprintf(stderr, "libusb_init failed\n");
        return 1;
    }

    libusb_device_handle *h =
        libusb_open_device_with_vid_pid(ctx, ROKID_VID, ROKID_PID);
    if (!h) {
        fprintf(stderr, "could not open %04x:%04x — are the glasses plugged in?\n",
                ROKID_VID, ROKID_PID);
        libusb_exit(ctx);
        return 1;
    }

    int rc = 0;
    unsigned char buf[0x40];

    if (strcmp(argv[1], "serial") == 0) {
        memset(buf, 0, sizeof buf);
        rc = libusb_control_transfer(h, req_in(), 0x81, 0x100, 0,
                                     buf, sizeof buf, TIMEOUT_MS);
        if (rc < 0) {
            fprintf(stderr, "read failed: %s (%d)\n", libusb_strerror(rc), rc);
        } else {
            buf[sizeof buf - 1] = 0;
            printf("serial: %s  (%d bytes)\n", buf, rc);
        }

    } else if (strcmp(argv[1], "get") == 0) {
        memset(buf, 0, sizeof buf);
        rc = libusb_control_transfer(h, req_in(), 0x81, 0x0, 0x1,
                                     buf, sizeof buf, TIMEOUT_MS);
        if (rc < 0) {
            fprintf(stderr, "read failed: %s (%d)\n", libusb_strerror(rc), rc);
        } else {
            printf("raw: ");
            for (int i = 0; i < (rc < 8 ? rc : 8); i++) printf("%02x ", buf[i]);
            printf("\ncurrent display mode: %d — %s\n", buf[1], mode_name(buf[1]));
        }

    } else if (strcmp(argv[1], "set") == 0) {
        if (argc != 3) { usage(argv[0]); libusb_close(h); libusb_exit(ctx); return 2; }
        int mode = atoi(argv[2]);
        if (mode != 0 && mode != 1 && mode != 3 && mode != 4) {
            fprintf(stderr, "mode must be 0, 1, 3 or 4\n");
            libusb_close(h); libusb_exit(ctx); return 2;
        }
        unsigned char payload[1] = {0};
        printf("setting mode %d — %s\n", mode, mode_name(mode));
        rc = libusb_control_transfer(h, req_out(), 0x1, (uint16_t)mode, 0x1,
                                     payload, sizeof payload, TIMEOUT_MS);
        if (rc < 0) {
            fprintf(stderr, "write failed: %s (%d)\n", libusb_strerror(rc), rc);
        } else {
            printf("OK (%d bytes)\n", rc);
        }

    } else {
        usage(argv[0]);
        rc = -1;
    }

    libusb_close(h);
    libusb_exit(ctx);
    return rc < 0 ? 1 : 0;
}
