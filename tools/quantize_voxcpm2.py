#!/usr/bin/env python3
"""VoxCPM2 GGUF 权重量化工具（T49 P0/P2）

把 GGUF 权重重写为目标量化格式，供 VoxCPM2 引擎（llama.cpp-omni）加载。

背景（T49 discussion.md 已固化的算子矩阵约束）：
  - BaseLM（minicpm4 标准架构）——llama.cpp 全格式支持（Q4_K_M/Q6_K/... 均可）
  - Acoustic（voxcpm-acoustic 自定义架构）——llama-quantize 不认此架构，只能本工具直写；
    且 ggml 的 cpy 反量化分发只支持 Q8_0/Q4_0/Q4_1/Q5_0/Q5_1（k-quant 进 AudioVAE 的
    ggml_cast 路径会 GGML_ABORT）⇒ 声学侧禁止使用 k-quant

分类规则（第一性原理：只量化"走 matmul/cpy-cast 的大权重"，其它一律原样）：
  - F32 张量（实测全部是 norm/rms）→ 原样保留（ggml binary_op 要求 norm 为 F32）
  - 小张量（< --min-elements，含 embed/bias/sr_cond 等）→ 原样保留
    （AudioVAE 的 get_rows 对量化 embed 支持不完整；小张量量化无收益）
  - Q8_0 源（BaseLM 现役）→ dequantize 到 F32 再量化到目标（二段量化，P3 门槛兜底）
  - F16 大张量（Acoustic 现役）→ 升 F32 后量化到目标

用法：
  python tools/quantize_voxcpm2.py <in.gguf> <out.gguf> --qtype Q8_0 [--min-elements 262144]
  python tools/quantize_voxcpm2.py <in.gguf> <out.gguf> --qtype Q4_K_M
  加 --dry-run 只出分类计划与体积估算，不写文件

写后自校验（T49 D2 对策，gguf 重写是经典事故位）：
  张量数/名字/shape/dtype 逐一比对；抽样量化张量反量化后与源做最大绝对误差报告。
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import gguf
from gguf import GGMLQuantizationType, GGUFReader, GGUFValueType, GGUFWriter

HEADER_KEYS = {"GGUF.version", "GGUF.tensor_count", "GGUF.kv_count", "GGUF.alignment"}


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="VoxCPM2 GGUF 权重量化工具")
    p.add_argument("input", type=Path)
    p.add_argument("output", type=Path)
    p.add_argument("--qtype", required=True, choices=[t.name for t in GGMLQuantizationType])
    p.add_argument("--min-elements", type=int, default=262144,
                   help="小于该元素数的张量保持原格式（默认 262144=512KB@F16）")
    p.add_argument("--dry-run", action="store_true")
    return p.parse_args()


def copy_kv(writer: GGUFWriter, reader: GGUFReader) -> int:
    """复制除头部字段与 general.architecture（构造函数已写）外的全部元数据。

    reader 的 field.parts 是原始缓冲区切片; 真实值必须用 field.contents() 解码
    (字符串/数组/标量均为 python 原生类型)。
    """
    n = 0
    for key, field in reader.fields.items():
        if key in HEADER_KEYS or key == "general.architecture":
            continue
        types = list(field.types)
        c = field.contents()
        vals = c if isinstance(c, (list, tuple)) else [c]
        if len(types) == 1:
            writer.add_key_value(key, vals[0], types[0])
        else:
            # 数组：types[0] 是 ARRAY，types[1] 是元素类型
            writer.add_key_value(key, vals, types[0], sub_type=types[1])
        n += 1
    return n


def main() -> int:
    args = parse_args()
    qtype = GGMLQuantizationType[args.qtype]
    if not args.input.is_file():
        print(f"[ERR] 输入不存在: {args.input}", file=sys.stderr)
        return 2

    reader = GGUFReader(str(args.input))
    arch = None
    for key, field in reader.fields.items():
        if key == "general.architecture":
            # contents() 才是解码值; parts 是原始缓冲区
            arch = str(field.contents())
    if arch is None:
        print("[ERR] 输入缺 general.architecture", file=sys.stderr)
        return 2

    # ---- 分类计划 ----
    block_size = gguf.GGML_QUANT_SIZES[qtype][0]
    plan: list[tuple[str, object, str, str]] = []  # (name, tensor, action, src_type)
    for t in reader.tensors:
        src = t.tensor_type.name
        big = t.n_elements >= args.min_elements
        # ggml 行量化约束: ne[0] 必须是 block_size 倍数。t.shape[0] = ne[0]
        # (注意: Q8_0 源的 data.shape[-1] 是字节宽 2176 不是 ne[0], 不能用)
        # VAE conv 张量 ne[0]=1/12/16 等不满足 -> 只能保持 F16(实测占声学 10.3% 参数)。
        row_ok = int(t.shape[0]) % block_size == 0
        if src == "F32" or not big or not row_ok:
            action, src_t = "keep", src
        elif src == "F16":
            action, src_t = "quantize", "F16"
        elif src == "Q8_0":
            action, src_t = "requantize", "Q8_0"
        else:
            print(f"[ERR] 未预期的源类型 {src} @ {t.name}", file=sys.stderr)
            return 2
        plan.append((t.name, t, action, src_t))

    n_keep = sum(1 for row in plan if row[2] == "keep")
    n_q = len(plan) - n_keep
    block_size, type_size = gguf.GGML_QUANT_SIZES[qtype]
    keep_bytes = sum(t.data.nbytes for name, t, a, _ in plan if a == "keep")
    q_bytes = sum(int(t.n_elements * type_size / block_size) for name, t, a, _ in plan if a != "keep")
    print(f"[plan] {args.input.name} -> {args.qtype}")
    print(f"  张量: {len(plan)}  量化 {n_q}  保持原格式 {n_keep}")
    print(f"  预计输出: ~{(keep_bytes + q_bytes) / 2**30:.2f} GB（保持 {keep_bytes/2**30:.2f} GB + 量化 {q_bytes/2**30:.2f} GB）")
    if args.dry_run:
        for name, t, a, s in plan:
            if a != "keep":
                print(f"  [q] {t.n_elements/1e6:8.2f}M {s:5s}->{args.qtype:6s} {name}")
        return 0

    # ---- 写入 ----
    args.output.parent.mkdir(parents=True, exist_ok=True)
    writer = GGUFWriter(str(args.output), arch=arch)
    n_kv = copy_kv(writer, reader)
    for name, t, action, _ in plan:
        if action == "keep":
            writer.add_tensor(name, np.ascontiguousarray(t.data))
            continue
        # reader 的 t.data 即 numpy 逻辑序(最后维 = ne[0]), 无需转置;
        # t.shape 是 ne 维表(首元素 = ne[0])。quantize/q8_0 dequantize 均直接可用。
        if action == "requantize":
            f32 = gguf.dequantize(t.data, GGMLQuantizationType.Q8_0)
        else:
            f32 = t.data
        f32 = np.ascontiguousarray(f32, dtype=np.float32)
        q = gguf.quantize(f32, qtype)
        # 不传 raw_shape: add_tensor 的 shape 契约=字节形状, quantize() 返回的即字节数组
        writer.add_tensor(name, q, raw_dtype=qtype)
    writer.write_header_to_file()
    writer.write_kv_data_to_file()
    writer.write_tensors_to_file()
    writer.close()
    out_gb = args.output.stat().st_size / 2**30
    print(f"[write] {args.output}  ({out_gb:.2f} GB, {n_kv} 个元数据字段)")

    # ---- 写后自校验（D2）----
    chk = GGUFReader(str(args.output))
    assert len(chk.tensors) == len(reader.tensors), "张量数不一致"
    bad = 0
    max_err = 0.0
    for t_new, (_, t_old, action, _) in zip(chk.tensors, plan):
        assert t_new.name == t_old.name, f"顺序/名字不一致: {t_new.name} vs {t_old.name}"
        if list(t_new.shape) != list(t_old.shape):
            print(f"[ERR] shape 不一致 {t_new.name}: {t_new.shape} vs {t_old.shape}", file=sys.stderr)
            bad += 1
            continue
        if action != "keep" and t_new.tensor_type.name != args.qtype:
            print(f"[ERR] 类型不符 {t_new.name}: {t_new.tensor_type.name}", file=sys.stderr)
            bad += 1
        if action != "keep":
            # 抽样误差：反量化新张量与源 F32 比对
            src_f32 = (gguf.dequantize(t_old.data, GGMLQuantizationType.Q8_0) if action == "requantize"
                       else t_old.data.astype(np.float32))
            new_f32 = gguf.dequantize(t_new.data, GGMLQuantizationType[args.qtype])
            if new_f32.size and src_f32.size:
                step = max(1, new_f32.size // 4096)
                e = float(np.abs(new_f32.flatten()[::step] - src_f32.flatten()[::step]).max())
                max_err = max(max_err, e)
    if bad:
        print(f"[ERR] 校验失败 {bad} 项", file=sys.stderr)
        return 1
    print(f"[verify] 张量数/shape/dtype 全部一致；抽样最大绝对误差 {max_err:.2e}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
