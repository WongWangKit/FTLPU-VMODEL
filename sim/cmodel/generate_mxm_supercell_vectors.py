"""Integer-only reference for BF16 DAZ / 64-bit alignment / FP32 RNE.

No host float arithmetic, and no emulation of the hardware compressor tree.
Vectors are generated under build/; they are not repository source artifacts.
"""
from pathlib import Path
import random

QNAN = 0x7FC00000


def round_shift(value, shift):
    if shift <= 0:
        return value << -shift
    quotient, remainder = divmod(value, 1 << shift)
    half = 1 << (shift - 1)
    return quotient + (remainder > half or (remainder == half and quotient & 1))


def fp32_from_integer(value, scale, zero_sign=0):
    """RNE of exact signed integer * 2**scale, including gradual underflow."""
    if value == 0:
        return zero_sign << 31
    sign = int(value < 0)
    magnitude = abs(value)
    exponent = magnitude.bit_length() - 1 + scale
    if exponent < -126:
        rounded = round_shift(magnitude, -149 - scale)
        return (sign << 31) | rounded  # Can round up to minimum normal.
    rounded = round_shift(magnitude, magnitude.bit_length() - 24)
    if rounded >= 1 << 24:
        rounded >>= 1
        exponent += 1
    if exponent > 127:
        return (sign << 31) | 0x7F800000
    return (sign << 31) | ((exponent + 127) << 23) | (rounded & 0x7FFFFF)


def fp32_classify(bits):
    exponent, fraction = (bits >> 23) & 255, bits & 0x7FFFFF
    return exponent == 255 and fraction != 0, exponent == 255 and fraction == 0


def fp32_add(a, b):
    an, ai = fp32_classify(a)
    bn, bi = fp32_classify(b)
    if an or bn or (ai and bi and ((a ^ b) >> 31)):
        return QNAN
    if ai or bi:
        return a if ai else b
    values = []
    for bits in (a, b):
        exponent, fraction = (bits >> 23) & 255, bits & 0x7FFFFF
        mantissa = ((1 << 23) | fraction) if exponent else fraction
        values.append(((-1 if bits >> 31 else 1) * mantissa,
                       exponent - 150 if exponent else -149))
    scale = min(e for _, e in values)
    value = sum(m << (e - scale) for m, e in values)
    return fp32_from_integer(value, scale, int(a == 0x80000000 and b == a))


def fp32_to_bf16(bits):
    """Integer RNE to BF16, gradual underflow, quiet NaNs with high payload."""
    nan, infinity = fp32_classify(bits)
    if nan:
        return (bits >> 16) | 0x40
    if infinity:
        return bits >> 16
    sign = (bits >> 31) << 15
    return sign | round_shift(bits & 0x7FFFFFFF, 16)


def bf16_dot(activation, weight):
    products = []
    nan = False
    infinities = set()
    for a, b in zip(activation, weight):
        ea, eb = (a >> 7) & 255, (b >> 7) & 255
        fa, fb = a & 127, b & 127
        sign = (a ^ b) >> 15
        az, bz = ea == 0, eb == 0  # Input DAZ.
        an, bn = ea == 255 and fa != 0, eb == 255 and fb != 0
        ai, bi = ea == 255 and fa == 0, eb == 255 and fb == 0
        nan |= an or bn or (az and bi) or (bz and ai)
        if not (an or bn or az or bz) and (ai or bi):
            infinities.add(sign)
        if an or bn or ai or bi or az or bz:
            continue
        product = (128 + fa) * (128 + fb)
        high = product.bit_length() - 1
        products.append((product << (15-high), ea+eb-254+high-14, sign))
    aligned_bits = 63 - (len(activation)-1).bit_length()
    common = max((e for _, e, _ in products), default=0)
    total, lost = 0, False
    for product, exponent, sign in products:
        full = product << (aligned_bits-16)
        distance = common-exponent
        truncated = full >> distance
        lost |= full != truncated << distance
        total += -truncated if sign else truncated
    if nan or len(infinities) == 2:
        return QNAN, lost
    if infinities:
        return (next(iter(infinities)) << 31) | 0x7F800000, lost
    return fp32_from_integer(total, common-(aligned_bits-1)), lost


def packed(values, width):
    return sum(value << (index*width) for index, value in enumerate(values))


def dot_cases(terms, count, rng):
    cases = []
    def add(a, b):
        cases.append((a[:terms], b[:terms]))
    for a, b in [(0, 0x3F80), (0x8000, 0x3F80), (0x3F80, 0x3F80),
                 (0xBF80, 0x4000), (0x007F, 0x7F7F), (0x807F, 0x3F80),
                 (0x0080, 0x3F00), (0x7F7F, 0x7F7F), (0x7F80, 0x3F80),
                 (0x7FC1, 0x3F80), (0, 0x7F80), (0x8000, 0x7F80)]:
        add([a]*terms, [b]*terms)
    if terms >= 2:
        add([0x7F7F,0xFF7F]+[0x3F80]*(terms-2), [0x7F7F]*2+[0x3F80]*(terms-2))
        add([0x7F80,0xFF80]+[0]*(terms-2), [0x3F80]*terms)
        add([0x3F80,0xBF80]+[0]*(terms-2), [0x3F80]*terms)
    # Explicit alignment-window boundaries and cancellation.
    for distance in [0,1,23,24,43,44,45,58,59,60,61,127,253]:
        if terms >= 2:
            small_exponent = max(1, 254-distance)
            add([0x7F7F, (small_exponent<<7)|127]+[0]*(terms-2), [0x3F80]*terms)
    while len(cases) < count:
        if len(cases) % 3 == 0:
            a = [rng.randrange(65536) for _ in range(terms)]
            b = [rng.randrange(65536) for _ in range(terms)]
        else:
            base = rng.randrange(24,232)
            a = [(rng.randrange(2)<<15)|(max(1,min(254,base+rng.randrange(-4,5)))<<7)|rng.randrange(128)
                 for _ in range(terms)]
            b = [(rng.randrange(2)<<15)|(rng.randrange(100,155)<<7)|rng.randrange(128)
                 for _ in range(terms)]
        if terms >= 2 and len(cases) % 5 == 0:
            a[1] = a[0] ^ 0x8000
            b[1] = b[0]
        add(a,b)
    return cases


def generate(directory, dot_count=2048, add_count=4096):
    directory.mkdir(parents=True, exist_ok=True)
    rng = random.Random(0x4D584D)
    # Reference sanity checks target exponent range, ties, signed zero and DAZ.
    assert fp32_add(0x3F800000,0x33800000) == 0x3F800000
    assert fp32_add(0x3F800001,0x33800000) == 0x3F800002
    assert fp32_add(0x00800000,0x807FFFFF) == 1
    assert bf16_dot([0x0080],[0x3F00])[0] == 0x00400000
    assert bf16_dot([0x007F],[0x3F80])[0] == 0
    assert fp32_to_bf16(0x3F808000)==0x3F80
    assert fp32_to_bf16(0x3F818000)==0x3F82
    assert fp32_to_bf16(0x7F7FFFFF)==0x7F80
    assert fp32_to_bf16(0x7F800001)==0x7FC0
    assert fp32_to_bf16(0x00008000)==0 and fp32_to_bf16(0x00008001)==1
    # All 65536 retained BF16 bit patterns, each with five discarded tails,
    # plus arbitrary FP32 patterns. The hardware uses no reference functions.
    with (directory/'output.hex').open('w') as stream:
        for high in range(65536):
            for low in (0,0x7FFF,0x8000,0x8001,0xFFFF):
                value=(high<<16)|low
                stream.write(f'{value:08x}{fp32_to_bf16(value):08x}\n')
        output_rng=random.Random(0x42463136)
        for _ in range(4096):
            value=output_rng.getrandbits(32)
            stream.write(f'{value:08x}{fp32_to_bf16(value):08x}\n')
    for terms in [1,3,8,16]:
        cases=dot_cases(terms,dot_count,rng)
        width=terms*32+33
        with (directory/f'dot_k{terms}.hex').open('w') as stream:
            for a,b in cases:
                result,lost=bf16_dot(a,b)
                value=(packed(a,16)<<(terms*16+33))|(packed(b,16)<<33)|(result<<1)|int(lost)
                stream.write(f'{value:0{(width+3)//4}x}\n')
    special=[0,0x80000000,1,0x007FFFFF,0x00800000,0x3F800000,0x3F800001,
             0x33800000,0x7F7FFFFF,0xFF7FFFFF,0x7F800000,0xFF800000,0x7FC00001]
    cases=[(a,b) for a in special for b in special]
    while len(cases)<add_count:
        a,b=rng.getrandbits(32),rng.getrandbits(32)
        if len(cases)%3==0:
            b=(a^0x80000000)+rng.randrange(-2,3)
            b &= 0xFFFFFFFF
        cases.append((a,b))
    with (directory/'fp32_add.hex').open('w') as stream:
        for a,b in cases:
            stream.write(f'{a:08x}{b:08x}{fp32_add(a,b):08x}\n')
    # Backend sequence covers every ordered pair of the four operations.
    operations=[1,0,0,1,0,2,0,3,1,1,2,1,3,2,2,3,3,0]
    assert len(set(zip(operations,operations[1:])))==16
    history=[[[0]*8 for _ in range(32)] for _ in range(4)]
    with (directory/'backend.hex').open('w') as stream, (directory/'backend_output.hex').open('w') as out_stream:
        for command,op in enumerate(operations):
            for address in range(32):
                for column in range(4):
                    new=[]
                    for lane in range(8):
                        index=command*1024+address*32+column*8+lane
                        value=special[index%len(special)] if index%4==0 else rng.getrandbits(32)
                        new.append(value)
                    old=history[column][address][:]
                    result=[fp32_add(a,b) for a,b in zip(new,old)] if op>=2 else new[:]
                    stream.write(f'{packed(new,32):064x}{packed(old,32):064x}{packed(result,32):064x}\n')
                    # Output format alternates across output instructions;
                    # SRAM history must always retain the unquantized FP32.
                    quantized=command%2==1 and op in (0,3)
                    output=[fp32_to_bf16(v) for v in result] if quantized else result
                    out_stream.write(f'{packed(output,32):064x}\n')
                    if op in (1,2): history[column][address]=result[:]
    return dot_count,add_count


if __name__ == '__main__':
    root=Path(__file__).resolve().parents[2]
    counts=generate(root/'build/mxm_supercell/vectors')
    print(f'Generated {counts[0]} dot cases per size and {counts[1]} FP32 add cases')
