import warnings;warnings.filterwarnings('ignore')
import gc,sys,torch,numpy as np,coremltools as ct
OUT = sys.argv[1]  # 저장할 폴더
import coremltools.optimize.coreml as cto
from transformers import Wav2Vec2ForCTC
MODEL="MahmoudAshraf/mms-300m-1130-forced-aligner"
N=544000  # 34초(30초 + 앞뒤 2초)
class W(torch.nn.Module):
    def __init__(s,m): super().__init__(); s.m=m
    # log_softmax는 Swift에서 Float32로 한다(fp16에서 하면 작은 확률이 0이 돼 log가 -inf가 된다).
    def forward(s,x): return s.m(x).logits
m=Wav2Vec2ForCTC.from_pretrained(MODEL,attn_implementation='eager').eval()
w=W(m).eval()
x=torch.randn(1,N)
with torch.inference_mode():
    tr=torch.jit.trace(w,x,check_trace=False)
print('traced')
del m; gc.collect()
ml=ct.convert(tr,inputs=[ct.TensorType(name='audio',shape=(1,N))],outputs=[ct.TensorType(name='logits')],
              compute_precision=ct.precision.FLOAT32,minimum_deployment_target=ct.target.iOS18,convert_to='mlprogram')
del tr; gc.collect()
print('converted')
# fp16 연산은 중간값이 넘쳐 NaN이 난다 → 연산은 fp32, 가중치만 32개 묶음 int8(iOS18+). 진단: diagnose_mms.py
cfg=cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(mode='linear_symmetric',granularity='per_block',block_size=32,weight_threshold=2048))
ml=cto.linear_quantize_weights(ml,config=cfg)
ml.short_description='MMS-300m forced aligner (1130 languages, romanized chars). Input: 34s mono 16kHz normalized audio. Output: CTC logits [1,1699,31] (apply log_softmax in float32)'
ml.save(OUT + '/LyricsAligner.mlpackage')
print('saved')
