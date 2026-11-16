#ifndef QUOTA_BAR_RUST_H
#define QUOTA_BAR_RUST_H

#include <stddef.h>
#include <stdint.h>

// Input buffers are borrowed synchronously. Output strings belong to owner;
// copy them before qb_claude_free and never free them with a Swift/C allocator.
typedef struct { const uint8_t *ptr; size_t len; } QBByteString;
typedef struct {
    uint32_t status;
    int64_t counts[5];
    QBByteString timestamp, model, message_id, request_id, uuid, speed;
    void *owner;
} QBClaudeResult;

enum {
    QB_CLAUDE_PARSED = 0,
    QB_CLAUDE_IGNORED = 1,
    QB_CLAUDE_FALLBACK = 2,
    QB_CLAUDE_INTERNAL_ERROR = 3,
    QB_CLAUDE_INVALID_ARGUMENT = 4
};
void qb_claude_decode(const uint8_t *bytes, size_t length, QBClaudeResult *output);
void qb_claude_free(void *owner);

// 0 missing, 1 indeterminate, 2 other. Top-level: 3 assistant, 4 event_msg,
// 5 turn_context. Payload: 3 thread_settings_applied, 4 token_count.
int32_t qb_classify_top_level(const uint8_t *bytes, size_t length);
int32_t qb_classify_payload(const uint8_t *bytes, size_t length);

// Callbacks run synchronously on the caller's thread. Their byte views must not
// escape the callback. A successful scan returns the last complete-line offset;
// failures return POSIX errno and never publish an offset.
typedef uint8_t (*QBLineWanted)(const uint8_t *bytes, size_t length, void *context);
typedef void (*QBLineHandle)(const uint8_t *bytes, size_t length, void *context);
int32_t qb_read_lines(const char *path, int64_t offset, uint8_t has_limit, int64_t limit,
                     QBLineWanted wanted, QBLineHandle handle, void *context, int64_t *consumed);

typedef struct {
    double input, output, cache_write, cache_write_1h, cache_read;
    double input_above, output_above, cache_write_above, cache_write_1h_above, cache_read_above;
    int64_t threshold_tokens;
    // Optional rates use bits 0...7 in the above order; threshold uses bit 8.
    uint32_t present;
} QBModelPricing;
typedef struct { int64_t input, output, cache_write, cache_write_1h, cache_read; } QBPricingTokens;
uint8_t qb_pricing_cost(const QBModelPricing *rates, const QBPricingTokens *tokens,
                        uint8_t long_context, double *out_cost);
double qb_pricing_cache_write_1h_rate(const QBModelPricing *rates, uint8_t long_context);

// Aggregation borrows disjoint caller-owned buffers synchronously. Group capacity is row_count.
// Null buffers are allowed for zero counts. A nonzero status invalidates every output buffer.
typedef struct { int64_t input, output, cache_write, cache_write_1h, cache_read; } QBAggregateTokens;
typedef struct {
    uint64_t day, key, model;
    QBAggregateTokens tokens;
    double cost;
    int64_t unpriced;
    uint8_t priced, fallback;
} QBAggregateRow;
typedef struct {
    uint64_t day, key;
    QBAggregateTokens tokens;
    double cost;
    uint8_t priced, fallback;
} QBAggregateGroup;
typedef struct { QBAggregateTokens tokens; double cost; int64_t unpriced; uint8_t priced; } QBAggregateDay;
typedef struct { double cost; int64_t tokens; uint8_t priced; } QBAggregateModel;
enum {
    QB_AGGREGATE_OK = 0,
    QB_AGGREGATE_INVALID_COUNTS = 1,
    QB_AGGREGATE_TOKEN_OVERFLOW = 2,
    QB_AGGREGATE_TOTAL_OVERFLOW = 3,
    QB_AGGREGATE_WINDOW_OVERFLOW = 4,
    QB_AGGREGATE_INVALID_COST = 5,
    QB_AGGREGATE_INVALID_ARGUMENT = 6,
    QB_AGGREGATE_INTERNAL_ERROR = 7
};
int32_t qb_aggregate_usage(const QBAggregateRow *rows, uint64_t row_count,
                           uint64_t day_count, uint64_t model_count,
                           QBAggregateGroup *groups, uint64_t *group_count,
                           QBAggregateDay *days, QBAggregateModel *models);

#endif
