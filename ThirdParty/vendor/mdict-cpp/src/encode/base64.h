/*
 * Copyright (c) 2025-Present
 * All rights reserved.
 *
 * This code is licensed under the BSD 3-Clause License.
 * See the LICENSE file for details.
 */

#ifndef MDICT_BASE64_H
#define MDICT_BASE64_H

#include <vector>
#include <string>
#include <stdexcept>
#include <cstdint>
#include <cctype>
#include <cmath>

constexpr char b64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

std::vector<uint8_t> hex_to_binary(const std::string& hex_str) {
    std::vector<uint8_t> binary;
    binary.reserve(hex_str.size());

    for(char c : hex_str) {
        uint8_t value;
        if(c >= 'a' && c <= 'f') {
            value = c - 'a' + 10;
        } else if(c >= 'A' && c <= 'F') {
            value = c - 'A' + 10;
        } else if(c >= '0' && c <= '9') {
            value = c - '0';
        } else {
            throw std::runtime_error("Invalid hex character");
        }
        binary.push_back(value);
    }

    return binary;
}

void fix_padding(std::string &base64, size_t orig_size) {
    // Remove existing padding
    while (!base64.empty() && base64.back() == '=') {
        base64.pop_back();
    }

    // Calculate required padding based on original data size
    size_t mod = orig_size % 3;
    if (mod == 1) {
        base64.append(2, '=');
    } else if (mod == 2) {
        base64.append(1, '=');
    }
}


std::string base64_from_hex(const std::string& hex_str) {
    std::vector<uint8_t> binary = hex_to_binary(hex_str);
    const size_t orig_size = binary.size();
    std::string base64;
    base64.reserve(static_cast<size_t>(std::ceil(orig_size * 4 / 6.0)) + 2);

    size_t i = 0;
    for(; i < orig_size; i += 3) {
        uint8_t byte1 = binary[i];
        uint8_t byte2 = (i + 1 < orig_size) ? binary[i + 1] : 0;
        uint8_t byte3 = (i + 2 < orig_size) ? binary[i + 2] : 0;

        uint8_t index1 = (byte1 << 2) | (byte2 >> 2);
        uint8_t index2 = ((byte2 & 0x3) << 4) | byte3;
        
        base64 += b64[index1];
        base64 += b64[index2];
    }

    //  fix_padding(base64, orig_size); doesnt work as by now, gives wrong output
    return base64;
}


#endif // MDICT_BASE64_H
