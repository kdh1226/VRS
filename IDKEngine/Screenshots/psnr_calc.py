import os
import math
from PIL import Image
import numpy as np

SCREENSHOTS_DIR = r"C:\Users\Administrator\Desktop\프로젝트_폴더\IDKEngine-master\IDKEngine\Screenshots"

def calculate_psnr(img1_path, img2_path):
    img1 = np.array(Image.open(img1_path).convert("RGB"), dtype=np.float64)
    img2 = np.array(Image.open(img2_path).convert("RGB"), dtype=np.float64)
    if img1.shape != img2.shape:
        img2 = np.array(Image.open(img2_path).convert("RGB").resize(
            (img1.shape[1], img1.shape[0])), dtype=np.float64)
    mse = np.mean((img1 - img2) ** 2)
    if mse == 0:
        return float('inf')
    return 20 * math.log10(255.0 / math.sqrt(mse))

# 기준 이미지
REF_NO_BLUR = {
    "5": "VRS X 모션블러 X_5(기준).jpg",
    "10": "VRS X 모션블러 X_10(기준).jpg",
    "15": "VRS X 모션블러 X_15(기준).jpg",
}

REF_BLUR = {
    "5": "VRS X 모션블러 O_5(기준).jpg",
    "10": "VRS X 모션블러 O_10(기준).jpg",
    "15": "VRS X 모션블러 O_15(기준).jpg",
}

# 비교 이미지
GROUP_NO_BLUR = [
    "VRS O 모션블러 X_5.jpg",
    "주파수맵 O 모션블러 X_5.jpg",
]

GROUP_BLUR = [
    "VRS O 모션블러 O MotionBlurVRS X_5.jpg",
    "VRS O 모션블러 O MotionBlurVRS O_5.jpg",
    "주파수맵 O 모션블러 O MotionBlurVRS X_5.jpg",
    "주파수맵 O 모션블러 O MotionBlurVRS O_5.jpg",
]

def run_group(title, ref_dict, compare_names):
    print(f"\n{'='*60}")
    print(f"{title}")
    print(f"{'='*60}")
    for sec, ref_name in ref_dict.items():
        ref_path = os.path.join(SCREENSHOTS_DIR, ref_name)
        if not os.path.exists(ref_path):
            print(f"기준 이미지 없음: {ref_name}")
            continue
        for cmp_name in compare_names:
            cmp_name_sec = cmp_name.replace("_5.", f"_{sec}.")
            cmp_path = os.path.join(SCREENSHOTS_DIR, cmp_name_sec)
            if not os.path.exists(cmp_path):
                print(f"파일 없음: {cmp_name_sec}")
                continue
            psnr = calculate_psnr(ref_path, cmp_path)
            print(f"[{sec}초] {cmp_name_sec} => PSNR: {psnr:.2f} dB")

run_group("모션블러 X 그룹", REF_NO_BLUR, GROUP_NO_BLUR)
run_group("모션블러 O 그룹", REF_BLUR, GROUP_BLUR)
