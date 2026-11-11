//! Minimal ISO/IEC 18004 QR Code (Model 2, Level L, Byte Mode) renderer for terminal pairing.
use std::io;

struct VersionSpec {
    version: usize,
    ec_per_block: usize,
    g1_blocks: usize,
    g1_data: usize,
    g2_blocks: usize,
    g2_data: usize,
    align: &'static [usize],
    version_bits: u32,
}

const SPECS: [VersionSpec; 10] = [
    VersionSpec {
        version: 1,
        ec_per_block: 7,
        g1_blocks: 1,
        g1_data: 19,
        g2_blocks: 0,
        g2_data: 0,
        align: &[],
        version_bits: 0,
    },
    VersionSpec {
        version: 2,
        ec_per_block: 10,
        g1_blocks: 1,
        g1_data: 34,
        g2_blocks: 0,
        g2_data: 0,
        align: &[6, 18],
        version_bits: 0,
    },
    VersionSpec {
        version: 3,
        ec_per_block: 15,
        g1_blocks: 1,
        g1_data: 55,
        g2_blocks: 0,
        g2_data: 0,
        align: &[6, 22],
        version_bits: 0,
    },
    VersionSpec {
        version: 4,
        ec_per_block: 20,
        g1_blocks: 1,
        g1_data: 80,
        g2_blocks: 0,
        g2_data: 0,
        align: &[6, 26],
        version_bits: 0,
    },
    VersionSpec {
        version: 5,
        ec_per_block: 26,
        g1_blocks: 1,
        g1_data: 108,
        g2_blocks: 0,
        g2_data: 0,
        align: &[6, 30],
        version_bits: 0,
    },
    VersionSpec {
        version: 6,
        ec_per_block: 18,
        g1_blocks: 2,
        g1_data: 68,
        g2_blocks: 0,
        g2_data: 0,
        align: &[6, 34],
        version_bits: 0,
    },
    VersionSpec {
        version: 7,
        ec_per_block: 20,
        g1_blocks: 2,
        g1_data: 78,
        g2_blocks: 0,
        g2_data: 0,
        align: &[6, 22, 38],
        version_bits: 0x07C94,
    },
    VersionSpec {
        version: 8,
        ec_per_block: 24,
        g1_blocks: 2,
        g1_data: 97,
        g2_blocks: 0,
        g2_data: 0,
        align: &[6, 24, 42],
        version_bits: 0x085BC,
    },
    VersionSpec {
        version: 9,
        ec_per_block: 30,
        g1_blocks: 2,
        g1_data: 116,
        g2_blocks: 0,
        g2_data: 0,
        align: &[6, 26, 46],
        version_bits: 0x09A99,
    },
    VersionSpec {
        version: 10,
        ec_per_block: 18,
        g1_blocks: 2,
        g1_data: 68,
        g2_blocks: 2,
        g2_data: 69,
        align: &[6, 28, 50],
        version_bits: 0x0A4D3,
    },
];

fn gf_mul(mut a: u8, mut b: u8) -> u8 {
    let mut p = 0u8;
    for _ in 0..8 {
        if (b & 1) != 0 {
            p ^= a;
        }
        let hi = (a & 0x80) != 0;
        a <<= 1;
        if hi {
            a ^= 0x1D;
        }
        b >>= 1;
    }
    p
}

fn rs_remainder(data: &[u8], degree: usize) -> Vec<u8> {
    let mut gen = vec![0u8; degree];
    gen[degree - 1] = 1;
    let mut root = 1u8;
    for _ in 0..degree {
        for j in 0..degree {
            gen[j] = gf_mul(gen[j], root);
            if j + 1 < degree {
                gen[j] ^= gen[j + 1];
            }
        }
        root = gf_mul(root, 2);
    }
    let mut rem = vec![0u8; degree];
    for &byte in data {
        let factor = byte ^ rem[0];
        rem.rotate_left(1);
        rem[degree - 1] = 0;
        for (r, &g) in rem.iter_mut().zip(gen.iter()) {
            *r ^= gf_mul(g, factor);
        }
    }
    rem
}

pub fn render_unicode(payload: &str) -> io::Result<String> {
    let matrix = encode_matrix(payload.as_bytes())?;
    let size = matrix.len();
    let quiet = 2isize;
    let total = size as isize + quiet * 2;
    let is_dark = |r: isize, c: isize| -> bool {
        let mr = r - quiet;
        let mc = c - quiet;
        if mr < 0 || mc < 0 || mr >= size as isize || mc >= size as isize {
            false
        } else {
            matrix[mr as usize][mc as usize]
        }
    };
    let mut out = String::new();
    let mut r = 0isize;
    while r < total {
        out.push_str("  ");
        for c in 0..total {
            let top = is_dark(r, c);
            let bottom = if r + 1 < total {
                is_dark(r + 1, c)
            } else {
                false
            };
            // Foreground = light module, background = dark module works on both
            // dark and light terminals when quiet zone is drawn as full blocks.
            let ch = match (top, bottom) {
                (false, false) => '█',
                (false, true) => '▀',
                (true, false) => '▄',
                (true, true) => ' ',
            };
            out.push(ch);
        }
        out.push('\n');
        r += 2;
    }
    Ok(out)
}

pub fn encode_matrix(payload: &[u8]) -> io::Result<Vec<Vec<bool>>> {
    let spec = SPECS
        .iter()
        .find(|s| {
            let total_data = s.g1_blocks * s.g1_data + s.g2_blocks * s.g2_data;
            let overhead = if s.version <= 9 { 2 } else { 3 };
            payload.len() + overhead <= total_data
        })
        .ok_or_else(|| io::Error::other("Pairing URL is too long for terminal QR rendering"))?;

    let total_data = spec.g1_blocks * spec.g1_data + spec.g2_blocks * spec.g2_data;
    let mut bits = Vec::with_capacity(total_data * 8);
    fn push_bits(bits: &mut Vec<bool>, val: usize, len: usize) {
        for i in (0..len).rev() {
            bits.push(((val >> i) & 1) != 0);
        }
    }
    push_bits(&mut bits, 0b0100, 4);
    push_bits(
        &mut bits,
        payload.len(),
        if spec.version <= 9 { 8 } else { 16 },
    );
    for &b in payload {
        push_bits(&mut bits, b as usize, 8);
    }
    let capacity_bits = total_data * 8;
    let term = (capacity_bits - bits.len()).min(4);
    push_bits(&mut bits, 0, term);
    while bits.len() % 8 != 0 {
        bits.push(false);
    }
    let mut data_bytes = Vec::with_capacity(total_data);
    for chunk in bits.chunks(8) {
        let mut byte = 0u8;
        for &bit in chunk {
            byte = (byte << 1) | u8::from(bit);
        }
        data_bytes.push(byte);
    }
    for (idx, pad) in (data_bytes.len()..total_data).enumerate() {
        let _ = pad;
        data_bytes.push(if idx % 2 == 0 { 0xEC } else { 0x11 });
    }

    let mut data_blocks = Vec::new();
    let mut ec_blocks = Vec::new();
    let mut offset = 0;
    for (count, len) in [
        (spec.g1_blocks, spec.g1_data),
        (spec.g2_blocks, spec.g2_data),
    ] {
        for _ in 0..count {
            let block = &data_bytes[offset..offset + len];
            offset += len;
            data_blocks.push(block.to_vec());
            ec_blocks.push(rs_remainder(block, spec.ec_per_block));
        }
    }

    let max_data_len = spec.g1_data.max(spec.g2_data);
    let mut codewords =
        Vec::with_capacity(total_data + (spec.g1_blocks + spec.g2_blocks) * spec.ec_per_block);
    for i in 0..max_data_len {
        for block in &data_blocks {
            if i < block.len() {
                codewords.push(block[i]);
            }
        }
    }
    for i in 0..spec.ec_per_block {
        for block in &ec_blocks {
            codewords.push(block[i]);
        }
    }

    let size = 17 + 4 * spec.version;
    let mut modules = vec![vec![false; size]; size];
    let mut is_func = vec![vec![false; size]; size];

    let mut set_func = |r: usize, c: usize, dark: bool| {
        modules[r][c] = dark;
        is_func[r][c] = true;
    };

    // Finder patterns + separators
    for &(fr, fc) in &[
        (0isize, 0isize),
        (0, size as isize - 7),
        (size as isize - 7, 0),
    ] {
        for dr in -1..=7 {
            for dc in -1..=7 {
                let r = fr + dr;
                let c = fc + dc;
                if r >= 0 && r < size as isize && c >= 0 && c < size as isize {
                    let dark = (0..=6).contains(&dr)
                        && (0..=6).contains(&dc)
                        && (dr == 0
                            || dr == 6
                            || dc == 0
                            || dc == 6
                            || ((2..=4).contains(&dr) && (2..=4).contains(&dc)));
                    set_func(r as usize, c as usize, dark);
                }
            }
        }
    }

    // Timing patterns
    for i in 8..size - 8 {
        set_func(6, i, i % 2 == 0);
        set_func(i, 6, i % 2 == 0);
    }

    // Alignment patterns
    for (i, &ar) in spec.align.iter().enumerate() {
        for (j, &ac) in spec.align.iter().enumerate() {
            if (i == 0 && j == 0)
                || (i == 0 && j + 1 == spec.align.len())
                || (i + 1 == spec.align.len() && j == 0)
            {
                continue;
            }
            for dr in -2isize..=2 {
                for dc in -2isize..=2 {
                    let dist = dr.abs().max(dc.abs());
                    set_func(
                        (ar as isize + dr) as usize,
                        (ac as isize + dc) as usize,
                        dist != 1,
                    );
                }
            }
        }
    }

    // Reserve format information areas and dark module
    for i in 0..9 {
        if i != 6 {
            set_func(8, i, false);
            set_func(i, 8, false);
        }
    }
    for i in 0..8 {
        set_func(8, size - 1 - i, false);
        set_func(size - 1 - i, 8, false);
    }
    set_func(size - 8, 8, true);

    // Version information (V7..=V10)
    if spec.version >= 7 {
        for i in 0..18 {
            let dark = ((spec.version_bits >> i) & 1) != 0;
            let a = size - 11 + (i % 3);
            let b = i / 3;
            set_func(a, b, dark);
            set_func(b, a, dark);
        }
    }

    // Zigzag data placement
    let mut bit_idx = 0usize;
    let total_bits = codewords.len() * 8;
    let mut right = size as isize - 1;
    let mut upward = true;
    while right >= 1 {
        if right == 6 {
            right -= 1;
        }
        for step in 0..size {
            let r = if upward { size - 1 - step } else { step };
            for dc in 0..2 {
                let c = (right - dc) as usize;
                if !is_func[r][c] {
                    let dark = if bit_idx < total_bits {
                        ((codewords[bit_idx / 8] >> (7 - (bit_idx % 8))) & 1) != 0
                    } else {
                        false
                    };
                    modules[r][c] = dark;
                    bit_idx += 1;
                }
            }
        }
        upward = !upward;
        right -= 2;
    }

    // Choose mask 0 ((r + c) % 2 == 0) and write format info for Level L (01)
    let mask = 0usize;
    for r in 0..size {
        for c in 0..size {
            if !is_func[r][c] && (r + c) % 2 == 0 {
                modules[r][c] = !modules[r][c];
            }
        }
    }
    let data = (0b01usize << 3) | mask;
    let mut rem = data << 10;
    for i in (10..15).rev() {
        if (rem & (1 << i)) != 0 {
            rem ^= 0x537 << (i - 10);
        }
    }
    let format_bits = ((data << 10) | rem) ^ 0x5412;
    let fbit = |i: usize| ((format_bits >> i) & 1) != 0;
    for (i, row) in modules.iter_mut().enumerate().take(6) {
        row[8] = fbit(i);
    }
    modules[7][8] = fbit(6);
    modules[8][8] = fbit(7);
    modules[8][7] = fbit(8);
    for i in 9..15 {
        modules[8][14 - i] = fbit(i);
    }
    for i in 0..8 {
        modules[8][size - 1 - i] = fbit(i);
    }
    for i in 8..15 {
        modules[size - 15 + i][8] = fbit(i);
    }

    Ok(modules)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_pairing_uri_into_valid_qr_matrix_and_unicode_blocks() {
        let uri = "omg://device?url=ws://192.168.1.42:8791&token=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        let matrix = encode_matrix(uri.as_bytes()).unwrap();
        assert_eq!(matrix.len(), 41); // Version 6 (41x41)
        assert!(matrix[0][0]);
        assert!(matrix[0][6]);
        assert!(matrix[6][0]);
        let rendered = render_unicode(uri).unwrap();
        assert!(rendered.contains('█'));
        assert!(rendered.lines().count() >= 22);
    }
}
