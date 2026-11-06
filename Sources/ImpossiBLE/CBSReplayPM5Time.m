#import "CBSReplayInternal.h"

// Moves a Concept2 PM5's clock in a recording to the time of the replay.
//
// A replayed workout otherwise carries the date and time the PM5 logged it
// under when it was recorded, and the Concept2 Logbook rejects it as a
// duplicate of the original ("Duplicate Result", HTTP 409): the app folds it
// into the existing entry and no new workout appears. Everything else is
// replayed byte for byte.
//
// All PM5 timestamps are shifted by one offset — the one that makes the last
// workout summary read as `now` — so their spacing (clock read at connect,
// workout logged minutes later) is kept. Fields rewritten:
//
//   CE060039 workout summary, CE06003A additional summary   bytes 0–3
//   CE060080 multiplexed 0x39 / 0x3A / 0x3C summaries       bytes 1–4
//   CSAFE replies on response channels (e.g. CE060022):
//     GET_DATETIME (0x85)                       hour 1–12, min, AM/PM, month, day, year
//     any other reply data holding a summary's date+time, little or big
//     endian (the logged workout record, 0x6A, is big endian)
//
// Log date/time is month (4 bits) | day (5) | year - 2000 (7), little endian,
// then minutes, hours (24 h), all on the PM5's local clock.

#if TARGET_OS_SIMULATOR

typedef struct {
    NSInteger year, month, day, hour, minute;
} CBSPM5Stamp;

static BOOL CBSPM5DecodeLogStamp(const uint8_t *b, CBSPM5Stamp *stamp)
{
    uint16_t date = (uint16_t)(b[0] | (b[1] << 8));
    CBSPM5Stamp s = {2000 + (date >> 9), date & 0x0F, (date >> 4) & 0x1F, b[3], b[2]};
    if (s.month < 1 || s.month > 12 || s.day < 1 || s.day > 31 || s.hour > 23 || s.minute > 59) return NO;
    *stamp = s;
    return YES;
}

static void CBSPM5EncodeLogStamp(CBSPM5Stamp s, uint8_t *b)
{
    uint16_t date = (uint16_t)((s.month & 0x0F) | ((s.day & 0x1F) << 4) | (((s.year - 2000) & 0x7F) << 9));
    b[0] = date & 0xFF;
    b[1] = date >> 8;
    b[2] = (uint8_t)s.minute;
    b[3] = (uint8_t)s.hour;
}

static NSDate *CBSPM5DateFromStamp(CBSPM5Stamp s)
{
    NSDateComponents *components = [NSDateComponents new];
    components.year = s.year;
    components.month = s.month;
    components.day = s.day;
    components.hour = s.hour;
    components.minute = s.minute;
    return [NSCalendar.currentCalendar dateFromComponents:components];
}

static CBSPM5Stamp CBSPM5StampFromDate(NSDate *date)
{
    NSDateComponents *c = [NSCalendar.currentCalendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay |
                                                                 NSCalendarUnitHour | NSCalendarUnitMinute
                                                        fromDate:date];
    return (CBSPM5Stamp){c.year, c.month, c.day, c.hour, c.minute};
}

/// Where the summary's date+time sits in a notification, or -1.
static NSInteger CBSPM5SummaryOffset(NSString *uuid, NSData *value)
{
    const uint8_t *b = value.bytes;
    if (([uuid hasPrefix:@"CE060039"] || [uuid hasPrefix:@"CE06003A"]) && value.length >= 4) return 0;
    if ([uuid hasPrefix:@"CE060080"] && value.length >= 5 && (b[0] == 0x39 || b[0] == 0x3A || b[0] == 0x3C)) return 1;
    return -1;
}

static NSString *CBSPM5CharacteristicUUID(id characteristicId)
{
    if (![characteristicId isKindOfClass:NSString.class]) return nil;
    NSArray<NSString *> *parts = [characteristicId componentsSeparatedByString:@":"];
    return parts.count >= 2 ? parts[parts.count - 2].uppercaseString : nil;
}

#pragma mark - CSAFE frames

static NSMutableData *CBSPM5Unstuff(NSData *frame)
{
    const uint8_t *b = frame.bytes;
    NSUInteger n = frame.length;
    if (n < 4 || b[0] != 0xF0 || b[n - 1] != 0xF2) return nil;
    NSMutableData *content = [NSMutableData dataWithCapacity:n];
    for (NSUInteger i = 1; i < n - 1; i++) {
        uint8_t c = b[i];
        if (c == 0xF3) {
            if (i + 1 >= n - 1 || b[i + 1] > 0x03) return nil;
            c = (uint8_t)(0xF0 + b[++i]);
        }
        [content appendBytes:&c length:1];
    }
    return content;
}

static NSData *CBSPM5Stuff(NSData *content)
{
    NSMutableData *frame = [NSMutableData dataWithCapacity:content.length + 4];
    uint8_t flag = 0xF0;
    [frame appendBytes:&flag length:1];
    const uint8_t *b = content.bytes;
    for (NSUInteger i = 0; i < content.length; i++) {
        if (b[i] >= 0xF0 && b[i] <= 0xF3) {
            uint8_t pair[2] = {0xF3, (uint8_t)(b[i] - 0xF0)};
            [frame appendBytes:pair length:2];
        } else {
            [frame appendBytes:&b[i] length:1];
        }
    }
    flag = 0xF2;
    [frame appendBytes:&flag length:1];
    return frame;
}

/// Rewrites GET_DATETIME data in a command list; wrappers are entered.
static BOOL CBSPM5RewriteDateTimeCommands(uint8_t *b, NSUInteger n, CBSPM5Stamp (^shift)(CBSPM5Stamp))
{
    BOOL changed = NO;
    NSUInteger i = 0;
    while (i + 1 < n) {
        uint8_t command = b[i];
        NSUInteger length = b[i + 1];
        uint8_t *data = b + i + 2;
        if (i + 2 + length > n) break;
        if (command == 0x7E || command == 0x7F || command == 0x76 || command == 0x77 || command == 0x1A) {
            changed |= CBSPM5RewriteDateTimeCommands(data, length, shift);
        } else if (command == 0x85 && length == 7) {
            NSInteger hour12 = data[0], meridiem = data[2];
            CBSPM5Stamp s = {(data[5] << 8) | data[6], data[3], data[4],
                             (hour12 % 12) + (meridiem ? 12 : 0), data[1]};
            if (s.month >= 1 && s.month <= 12 && s.day >= 1 && s.minute <= 59 && hour12 >= 1 && hour12 <= 12) {
                CBSPM5Stamp t = shift(s);
                data[0] = (uint8_t)(t.hour % 12 == 0 ? 12 : t.hour % 12);
                data[1] = (uint8_t)t.minute;
                data[2] = t.hour >= 12 ? 1 : 0;
                data[3] = (uint8_t)t.month;
                data[4] = (uint8_t)t.day;
                data[5] = (uint8_t)(t.year >> 8);
                data[6] = (uint8_t)(t.year & 0xFF);
                changed = YES;
            }
        }
        i += 2 + length;
    }
    return changed;
}

/// The frame with its PM5 timestamps moved, or nil when nothing changed.
static NSData *CBSPM5RewriteCSAFEReply(NSData *frame, NSArray<NSData *> *logStamps, CBSPM5Stamp (^shift)(CBSPM5Stamp))
{
    NSMutableData *content = CBSPM5Unstuff(frame);
    if (content.length < 3) return nil;
    uint8_t *b = content.mutableBytes;
    // Extended reply: destination 00, source FD (the PM), then status.
    NSUInteger header = (content.length >= 4 && b[0] == 0x00 && b[1] == 0xFD) ? 2 : 0;
    NSUInteger start = header + 1;
    NSUInteger end = content.length - 1; // checksum
    if (start >= end) return nil;

    BOOL changed = CBSPM5RewriteDateTimeCommands(b + start, end - start, shift);
    // The logged-workout record (0x6A) holds the same stamp big endian: date
    // high byte first, then hours, minutes.
    for (NSData *stamp in logStamps) {
        const uint8_t *le = stamp.bytes;
        uint8_t be[4] = {le[1], le[0], le[3], le[2]};
        for (NSUInteger i = start; i + 4 <= end; i++) {
            BOOL little = memcmp(b + i, le, 4) == 0;
            if (!little && memcmp(b + i, be, 4) != 0) continue;
            uint8_t normal[4] = {b[i], b[i + 1], b[i + 2], b[i + 3]};
            if (!little) {
                normal[0] = b[i + 1]; normal[1] = b[i];
                normal[2] = b[i + 3]; normal[3] = b[i + 2];
            }
            CBSPM5Stamp s;
            if (!CBSPM5DecodeLogStamp(normal, &s)) continue;
            CBSPM5EncodeLogStamp(shift(s), normal);
            if (little) {
                memcpy(b + i, normal, 4);
            } else {
                b[i] = normal[1]; b[i + 1] = normal[0];
                b[i + 2] = normal[3]; b[i + 3] = normal[2];
            }
            changed = YES;
            i += 3;
        }
    }
    if (!changed) return nil;

    uint8_t checksum = 0;
    for (NSUInteger i = header; i < end; i++) checksum ^= b[i];
    b[end] = checksum;
    return CBSPM5Stuff(content);
}

#pragma mark - Recording

NSArray<CBSReplayEntry *> *CBSReplayShiftPM5Times(NSArray<CBSReplayEntry *> *entries,
                                                  NSDate *now,
                                                  NSSet<NSString *> *responseChannels)
{
    // The summaries' log stamps, and the last one as the reference.
    NSMutableArray<NSData *> *logStamps = [NSMutableArray array];
    BOOL haveReference = NO;
    CBSPM5Stamp reference = {0};
    for (CBSReplayEntry *entry in entries) {
        if (entry.fromClient || ![entry.type isEqualToString:@"didUpdateValue"]) continue;
        id value = entry.message[@"value"];
        NSData *bytes = [value isKindOfClass:NSString.class] ? [[NSData alloc] initWithBase64EncodedString:value options:0] : nil;
        NSInteger offset = bytes ? CBSPM5SummaryOffset(CBSPM5CharacteristicUUID(entry.message[@"characteristicId"]), bytes) : -1;
        if (offset < 0) continue;
        NSData *stamp = [bytes subdataWithRange:NSMakeRange(offset, 4)];
        CBSPM5Stamp decoded;
        if (!CBSPM5DecodeLogStamp(stamp.bytes, &decoded)) continue;
        if (![logStamps containsObject:stamp]) [logStamps addObject:stamp];
        reference = decoded;
        haveReference = YES;
    }

    // Without a workout summary, keep the PM5 clock's distance from the
    // recording's own start.
    NSDate *referenceDate = haveReference ? CBSPM5DateFromStamp(reference) : entries.firstObject.timestamp;
    if (!referenceDate) return entries;
    NSTimeInterval offset = floor(now.timeIntervalSinceReferenceDate / 60) * 60 - referenceDate.timeIntervalSinceReferenceDate;
    CBSPM5Stamp (^shift)(CBSPM5Stamp) = ^CBSPM5Stamp(CBSPM5Stamp s) {
        NSDate *date = CBSPM5DateFromStamp(s);
        return date ? CBSPM5StampFromDate([date dateByAddingTimeInterval:offset]) : s;
    };

    NSUInteger rewritten = 0;
    for (CBSReplayEntry *entry in entries) {
        if (entry.fromClient || ![entry.type isEqualToString:@"didUpdateValue"]) continue;
        id value = entry.message[@"value"];
        if (![value isKindOfClass:NSString.class]) continue;
        NSData *bytes = [[NSData alloc] initWithBase64EncodedString:value options:0];
        if (bytes.length == 0) continue;
        NSString *uuid = CBSPM5CharacteristicUUID(entry.message[@"characteristicId"]);

        NSData *replacement = nil;
        NSInteger summaryOffset = CBSPM5SummaryOffset(uuid, bytes);
        if (summaryOffset >= 0) {
            CBSPM5Stamp s;
            NSMutableData *copy = [bytes mutableCopy];
            uint8_t *b = (uint8_t *)copy.mutableBytes + summaryOffset;
            if (CBSPM5DecodeLogStamp(b, &s)) {
                CBSPM5EncodeLogStamp(shift(s), b);
                replacement = copy;
            }
        } else {
            for (NSString *channel in responseChannels) {
                if ([uuid hasPrefix:channel]) {
                    replacement = CBSPM5RewriteCSAFEReply(bytes, logStamps, shift);
                    break;
                }
            }
        }
        if (!replacement) continue;

        NSMutableDictionary *message = [entry.message mutableCopy];
        message[@"value"] = [replacement base64EncodedStringWithOptions:0];
        entry.message = message;
        rewritten++;
    }
    if (rewritten > 0) {
        NSLog(@"ImpossiBLE: replay moved %lu PM5 timestamps by %.0f min to the current time",
              (unsigned long)rewritten, offset / 60);
    }
    return entries;
}

#endif
