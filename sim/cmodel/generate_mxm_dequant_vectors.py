"""Exact rational oracle for INT8 affine weight loading, independent of RTL.

No host float, BF16 multiplier imitation, FP32 intermediate or RTL helpers.
"""
from fractions import Fraction
from pathlib import Path


def power2(exponent):
    return Fraction(1 << exponent) if exponent >= 0 else Fraction(1,1 << -exponent)


def rounded_integer(value):
    quotient,remainder=divmod(value.numerator,value.denominator)
    twice=remainder*2
    return quotient+(twice>value.denominator or (twice==value.denominator and quotient%2==1))


def dequantize(q,z,scale):
    q=q if q<128 else q-256
    z=z if z<128 else z-256
    difference=q-z
    sign=((scale>>15) ^ (difference<0)) << 15
    exponent=(scale>>7)&255
    fraction=scale&127
    if exponent==255:
        return 0x7fc0 if fraction or difference==0 else sign|0x7f80
    if difference==0 or scale&0x7fff==0:
        return sign
    # Decode the scale into an exact rational, apply affine dequantization,
    # then choose the nearest BF16 lattice point, ties to an even significand.
    magnitude=abs(difference)*Fraction((128+fraction) if exponent else fraction)*power2(exponent-134 if exponent else -133)
    high=magnitude.numerator.bit_length()-magnitude.denominator.bit_length()
    if magnitude<power2(high): high-=1
    quantum=max(high-7,-133)
    units=rounded_integer(magnitude/power2(quantum))
    if high < -126:
        return sign|units
    if units>=256:
        units>>=1;high+=1
    if high>127:
        return sign|0x7f80
    return sign|((high+127)<<7)|(units&127)


def generate(directory):
    directory=Path(directory);directory.mkdir(parents=True,exist_ok=True)
    assert dequantize(128,127,0x3f80)==0xc37f # -255, no INT8 saturation.
    assert dequantize(1,0,1)==1
    assert dequantize(0,0,0x7f80)==0x7fc0
    count=0
    with (directory/'weight_dequant.hex').open('w',encoding='ascii') as stream:
        def emit(q,z,s):
            nonlocal count
            stream.write(f'{q:02x}{z:02x}{s:04x}{dequantize(q,z,s):04x}{dequantize(q,0,s):04x}\n')
            count+=1
        # Every q/zero pair, including +/-255 differences, with varied scales.
        selected=[0x3f80,0x3fef,0x3fff,0x7f7f,1,0x007f,0x7f80,0x7fc0]
        for q in range(256):
            for z in range(256): emit(q,z,selected[(q+3*z)%len(selected)])
        # Every scale encoding for zero, normal/sign/carry/overflow-sensitive
        # positive and negative integer differences, including all subnormals.
        for s in range(65536):
            for q,z in [(0,0),(1,0),(255,0),(127,0),(128,0),(127,128),(128,127)]: emit(q,z,s)
    return count


if __name__=='__main__':
    print(generate(Path(__file__).resolve().parents[2]/'build/mxm_supercell/vectors'))
