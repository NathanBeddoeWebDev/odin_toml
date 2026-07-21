// Test-only adapter for the pinned upstream binary64-to-decimal oracle.
// The upstream source and dual-license texts are recorded beside this file.
#include "ryu/ryu.h"

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static size_t append_exponent(char *buffer, size_t index, int exponent) {
    buffer[index++] = 'e';
    if (exponent < 0) {
        buffer[index++] = '-';
        exponent = -exponent;
    }
    char reversed[3];
    size_t count = 0;
    if (exponent == 0) {
        reversed[count++] = '0';
    }
    while (exponent > 0) {
        reversed[count++] = (char)('0' + exponent % 10);
        exponent /= 10;
    }
    while (count > 0) {
        buffer[index++] = reversed[--count];
    }
    return index;
}

static size_t canonical_from_ryu(uint64_t bits, char *result) {
    double value;
    memcpy(&value, &bits, sizeof(value));
    char ryu[32];
    int ryu_count = d2s_buffered_n(value, ryu);
    ryu[ryu_count] = '\0';

    if (strcmp(ryu, "NaN") == 0) {
        memcpy(result, "nan", 3);
        return 3;
    }
    if (strcmp(ryu, "Infinity") == 0) {
        memcpy(result, "inf", 3);
        return 3;
    }
    if (strcmp(ryu, "-Infinity") == 0) {
        memcpy(result, "-inf", 4);
        return 4;
    }
    if (strcmp(ryu, "0E0") == 0) {
        memcpy(result, "0.0", 3);
        return 3;
    }
    if (strcmp(ryu, "-0E0") == 0) {
        memcpy(result, "-0.0", 4);
        return 4;
    }

    const char *cursor = ryu;
    int negative = *cursor == '-';
    if (negative) {
        ++cursor;
    }
    char digits[17];
    size_t digit_count = 0;
    while (*cursor != 'E') {
        if (*cursor != '.') {
            digits[digit_count++] = *cursor;
        }
        ++cursor;
    }
    int scientific_exponent = (int)strtol(cursor + 1, NULL, 10);
    int decimal_point = scientific_exponent + 1;

    char fixed[384];
    size_t fixed_count = 0;
    if (decimal_point <= 0) {
        fixed[fixed_count++] = '0';
        fixed[fixed_count++] = '.';
        for (int i = 0; i < -decimal_point; ++i) {
            fixed[fixed_count++] = '0';
        }
        memcpy(fixed + fixed_count, digits, digit_count);
        fixed_count += digit_count;
    } else if ((size_t)decimal_point >= digit_count) {
        memcpy(fixed + fixed_count, digits, digit_count);
        fixed_count += digit_count;
        for (int i = (int)digit_count; i < decimal_point; ++i) {
            fixed[fixed_count++] = '0';
        }
        fixed[fixed_count++] = '.';
        fixed[fixed_count++] = '0';
    } else {
        memcpy(fixed + fixed_count, digits, (size_t)decimal_point);
        fixed_count += (size_t)decimal_point;
        fixed[fixed_count++] = '.';
        memcpy(fixed + fixed_count, digits + decimal_point, digit_count - (size_t)decimal_point);
        fixed_count += digit_count - (size_t)decimal_point;
    }

    char scientific[24];
    size_t scientific_count = 0;
    scientific[scientific_count++] = digits[0];
    if (digit_count > 1) {
        scientific[scientific_count++] = '.';
        memcpy(scientific + scientific_count, digits + 1, digit_count - 1);
        scientific_count += digit_count - 1;
    }
    scientific_count = append_exponent(scientific, scientific_count, scientific_exponent);

    const char *selected = fixed;
    size_t selected_count = fixed_count;
    if (scientific_count < fixed_count) {
        selected = scientific;
        selected_count = scientific_count;
    }
    size_t result_count = 0;
    if (negative) {
        result[result_count++] = '-';
    }
    memcpy(result + result_count, selected, selected_count);
    return result_count + selected_count;
}

int main(void) {
    char line[128];
    size_t ordinal = 0;
    while (fgets(line, sizeof(line), stdin) != NULL) {
        ++ordinal;
        char *separator = strchr(line, '\t');
        if (separator == NULL) {
            fprintf(stderr, "oracle input line %zu has no separator\n", ordinal);
            return 2;
        }
        *separator = '\0';
        char *actual = separator + 1;
        actual[strcspn(actual, "\r\n")] = '\0';
        uint64_t bits = strtoull(line, NULL, 16);
        char expected[384];
        size_t expected_count = canonical_from_ryu(bits, expected);
        expected[expected_count] = '\0';
        if (strcmp(actual, expected) != 0) {
            fprintf(stderr, "oracle mismatch at line %zu for %016" PRIx64 ": expected %s, got %s\n",
                    ordinal, bits, expected, actual);
            return 1;
        }
    }
    if (ordinal == 0) {
        fprintf(stderr, "oracle received no vectors\n");
        return 2;
    }
    printf("pinned oracle agreed with %zu binary64 vectors\n", ordinal);
    return 0;
}
