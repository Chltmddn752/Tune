import warnings;warnings.filterwarnings('ignore')
import numpy as np, torch, onnx, onnxruntime as ort
from onnx2torch import convert
import coremltools as ct
m=onnx.load('/home/claude/work/models/UVR-MDX-NET-Voc_FT.onnx')
tm=convert(m).eval()
x=np.random.randn(1,4,3072,256).astype(np.float32)
sess=ort.InferenceSession('/home/claude/work/models/UVR-MDX-NET-Voc_FT.onnx')
ref=sess.run(None,{'input':x})[0]
with torch.no_grad(): out=tm(torch.from_numpy(x)).numpy()
print('torch vs onnx max abs', np.abs(out-ref).max(), 'ref scale', np.abs(ref).max())
del ref,out,sess,m; import gc; gc.collect()
tr=torch.jit.trace(tm, torch.from_numpy(x))
ml=ct.convert(tr, inputs=[ct.TensorType(name='spec', shape=(1,4,3072,256))], outputs=[ct.TensorType(name='vocals')],
              compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.iOS17, convert_to='mlprogram')
ml.short_description='UVR-MDX-NET-Voc_FT vocal separation (input: STFT real/imag of L/R, 3072 bins x 256 frames)'
ml.save('/home/claude/coreml/VocalSeparator.mlpackage')
print('saved')
