import warnings;warnings.filterwarnings('ignore')
import gc,torch,numpy as np,coremltools as ct
import coremltools.optimize.coreml as cto
from transformers import Wav2Vec2ForCTC
MODEL="MahmoudAshraf/mms-300m-1130-forced-aligner"
N=544000  # 34초(30초 + 앞뒤 2초)
class W(torch.nn.Module):
    def __init__(s,m): super().__init__(); s.m=m
    def forward(s,x): return torch.log_softmax(s.m(x).logits,-1)
m=Wav2Vec2ForCTC.from_pretrained(MODEL,cache_dir='/home/claude/work/models/hf',attn_implementation='eager').eval()
w=W(m).eval()
x=torch.randn(1,N)
with torch.inference_mode():
    tr=torch.jit.trace(w,x,check_trace=False)
print('traced')
del m; gc.collect()
ml=ct.convert(tr,inputs=[ct.TensorType(name='audio',shape=(1,N))],outputs=[ct.TensorType(name='logprobs')],
              compute_precision=ct.precision.FLOAT16,minimum_deployment_target=ct.target.iOS17,convert_to='mlprogram')
del tr; gc.collect()
print('converted')
cfg=cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(mode='linear_symmetric',granularity='per_channel',weight_threshold=2048))
ml=cto.linear_quantize_weights(ml,config=cfg)
ml.short_description='MMS-300m forced aligner (1130 languages, romanized chars). Input: 34s mono 16kHz normalized audio. Output: CTC log-probs [1,1700,31]'
ml.save('/home/claude/coreml/LyricsAligner.mlpackage')
print('saved')
