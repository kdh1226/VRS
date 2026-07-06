import os
import math
from PIL import Image
import numpy as np

# 기준 이미지 경로
SCREENSHOTS_DIR = r"C:\Users\Administrator\Desktop\프로젝트_폴더\IDKEngine-master\IDKEngine\Screenshots"

# 기준 이미지 이름 (VRS X 모션블러 X)
REFERENCE_IMAGES = {
    "5": "VRS X 모션블러 X_5(기준).jpg",
    "10": "VRS X 모션블러 X_10(기준).jpg",
    "15": "VRS X 모션블러 X_15(기준).jpg",
}

def calculate_psnr(img1_path, img2_path):
    img1 = np.array(Image.open(img1_path).convert("RGB"), dtype=np.float64)
    img2 = np.array(Image.open(img2_path).convert("RGB"), dtype=np.float64)

    if img1.shape != img2.shape:
        img2 = np.array(Image.open(img2_path).convert("RGB").resize(
            (img1.shape[1], img1.shape[0])), dtype=np.float64)

    mse = np.mean((img1 - img2) ** 2)
    if mse == 0:
        return float('inf')

    psnr = 20 * math.log10(255.0 / math.sqrt(mse))
    return psnr

def main():
    files = os.listdir(SCREENSHOTS_DIR)
    compare_files = [f for f in files if f not in REFERENCE_IMAGES.values()]

    results = []

    for sec, ref_name in REFERENCE_IMAGES.items():
        ref_path = os.path.join(SCREENSHOTS_DIR, ref_name)
        if not os.path.exists(ref_path):
            print(f"기준 이미지 없음: {ref_name}")
            continue

        # 같은 시간대 비교 이미지 찾기
        for cmp_file in sorted(compare_files):
            if f"_{sec}." in cmp_file or f"_{sec}(" in cmp_file:
                cmp_path = os.path.join(SCREENSHOTS_DIR, cmp_file)
                psnr = calculate_psnr(ref_path, cmp_path)
                results.append((cmp_file, sec, psnr))
                print(f"[{sec}초] {cmp_file} vs {ref_name} => PSNR: {psnr:.2f} dB")

    # 결과 파일 저장
    result_path = os.path.join(SCREENSHOTS_DIR, "psnr_results.txt")
    with open(result_path, "w", encoding="utf-8") as f:
        f.write("PSNR 측정 결과\n")
        f.write("=" * 60 + "\n")
        for cmp_file, sec, psnr in results:
            f.write(f"[{sec}초] {cmp_file} => {psnr:.2f} dB\n")

    print(f"\n결과 저장 완료: {result_path}")

if __name__ == "__main__":
    main()
