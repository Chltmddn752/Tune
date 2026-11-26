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

fp16 = ct.convert(tr, inputs=[ct.TensorType(name="audio", shape=(1, N))], outputs=[ct.TensorType(name="logits")],
                  compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.iOS17, convert_to="mlprogram")
check("fp16", fp16)
cfg = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric", granularity="per_channel", weight_threshold=2048))
check("fp16 + int8 weights", cto.linear_quantize_weights(fp16, config=cfg))
fp32 = ct.convert(tr, inputs=[ct.TensorType(name="audio", shape=(1, N))], outputs=[ct.TensorType(name="logits")],
                  compute_precision=ct.precision.FLOAT32, minimum_deployment_target=ct.target.iOS17, convert_to="mlprogram")
check("fp32", fp32)
check("fp32 + int8 weights", cto.linear_quantize_weights(fp32, config=cfg))
