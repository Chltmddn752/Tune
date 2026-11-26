"""MMS Core ML 변환 품질 진단(macOS): 같은 34초 입력에서 PyTorch fp32와 Core ML 변형들의 프레임별 최고 글자 일치율."""
import gc, sys, warnings
warnings.filterwarnings("ignore")
import numpy as np, soundfile as sf, torch, coremltools as ct
import coremltools.optimize.coreml as cto
from scipy.signal import resample_poly
from transformers import Wav2Vec2ForCTC

MODEL = "MahmoudAshraf/mms-300m-1130-forced-aligner"
N = 544000
x, sr = sf.read(sys.argv[1], dtype="float32")
x = resample_poly(x.mean(1), 160, 441).astype(np.float32)[:N]
x = (x - x.mean()) / (x.std() + 1e-7)
inp = np.zeros((1, N), np.float32); inp[0, :len(x)] = x

class W(torch.nn.Module):
    def __init__(s, m): super().__init__(); s.m = m
    def forward(s, a): return s.m(a).logits

m = Wav2Vec2ForCTC.from_pretrained(MODEL, attn_implementation="eager").eval()
with torch.inference_mode():
    ref = m(torch.from_numpy(inp)).logits[0].numpy()
    tr = torch.jit.trace(W(m).eval(), torch.from_numpy(inp), check_trace=False)
del m; gc.collect()
print("ref logits range", ref.min(), ref.max())

def check(name, ml):
    for cu in [ct.ComputeUnit.CPU_ONLY, ct.ComputeUnit.CPU_AND_GPU]:
        ml.save("/tmp/d.mlpackage")
        mm = ct.models.MLModel("/tmp/d.mlpackage", compute_units=cu)
        out = mm.predict({"audio": inp})["logits"][0].astype(np.float32)
        n = min(len(out), len(ref))
        agree = (out[:n].argmax(1) == ref[:n].argmax(1)).mean()
        print(f"{name:28s} {str(cu):28s} argmax agree {agree:.4f}  max|diff| {np.abs(out[:n]-ref[:n]).max():.2f} nan {np.isnan(out).any()}")

def const_names(ml, keys):
    names = []
    for fn in ml._mil_program.functions.values():
        for op in fn.operations:
            if op.op_type == "const" and any(k in op.name for k in keys):
                names.append(op.name)
    return names

fp32 = ct.convert(tr, inputs=[ct.TensorType(name="audio", shape=(1, N))], outputs=[ct.TensorType(name="logits")],
                  compute_precision=ct.precision.FLOAT32, minimum_deployment_target=ct.target.iOS17, convert_to="mlprogram")
pos = const_names(fp32, ["pos_conv"])
fe = const_names(fp32, ["feature_extractor", "conv_layers"])
print("pos_conv consts", pos[:6], "feature consts", len(fe))
base = cto.OpLinearQuantizerConfig(mode="linear_symmetric", granularity="per_channel", weight_threshold=2048)
check("fp32 + int8 (no pos_conv)", cto.linear_quantize_weights(fp32, config=cto.OptimizationConfig(global_config=base, op_name_configs={n: None for n in pos})))
check("fp32 + int8 (no pos_conv, no feat)", cto.linear_quantize_weights(fp32, config=cto.OptimizationConfig(global_config=base, op_name_configs={n: None for n in pos + fe})))
check("fp32 + int8 per_block32", cto.linear_quantize_weights(fp32, config=cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric", granularity="per_block", block_size=32, weight_threshold=2048), op_name_configs={n: None for n in pos})))
del fp32; gc.collect()
keep32 = {"layer_norm", "softmax", "reduce_mean", "reduce_sum", "pow", "sqrt", "rsqrt", "real_div", "gelu", "batch_norm", "instance_norm"}
mixed = ct.convert(tr, inputs=[ct.TensorType(name="audio", shape=(1, N))], outputs=[ct.TensorType(name="logits")],
                   compute_precision=ct.transform.FP16ComputePrecision(op_selector=lambda op: op.op_type not in keep32),
                   minimum_deployment_target=ct.target.iOS17, convert_to="mlprogram")
check("fp16 except norms/softmax", mixed)
