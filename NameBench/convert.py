"""F021 3.3 · Turns the downloaded name model into a Core ML file, once, by hand.

Usage, with Python started isolated and from outside the download folder:
    ~/Library/Caches/causabee-bench/venv/bin/python -I NameBench/convert.py \
        ~/Library/Caches/causabee-bench/model  <out folder>

Reads the model folder, writes <out>/NameNER.mlpackage, the tokenizer's files (tokenizer.json,
tokenizer_config.json, vocab.txt) and config.json beside it, and checks that Core ML and torch
agree on a few made-up sentences. Downloads nothing. The bench's code never runs this.
"""
import json
import shutil
import sys
from pathlib import Path

import numpy as np
import torch
import coremltools as ct
from transformers import AutoTokenizer, AutoModelForTokenClassification

LENGTH = 256  # tokens per window, [CLS] and [SEP] included; the bench cuts longer texts

source, out = Path(sys.argv[1]).expanduser(), Path(sys.argv[2]).expanduser()
out.mkdir(parents=True, exist_ok=True)

tokenizer = AutoTokenizer.from_pretrained(source, use_fast=True)
model = AutoModelForTokenClassification.from_pretrained(source, torchscript=True).eval()


class Logits(torch.nn.Module):
    def __init__(self, inner):
        super().__init__()
        self.inner = inner

    def forward(self, input_ids, attention_mask):
        return self.inner(input_ids=input_ids, attention_mask=attention_mask)[0]


example = tokenizer("Anja Sonntag wohnt in der Hechtstraße in Dresden.", padding="max_length",
                    max_length=LENGTH, truncation=True, return_tensors="pt")
traced = torch.jit.trace(Logits(model), (example["input_ids"], example["attention_mask"]))

mlmodel = ct.convert(
    traced,
    convert_to="mlprogram",
    inputs=[ct.TensorType(name="input_ids", shape=(1, LENGTH), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, LENGTH), dtype=np.int32)],
    outputs=[ct.TensorType(name="logits", dtype=np.float32)],
    minimum_deployment_target=ct.target.iOS18,
)
mlmodel.short_description = "Davlan/distilbert-base-multilingual-cased-ner-hrl (AFL-3.0), token classification, F021 bench only"
mlmodel.save(str(out / "NameNER.mlpackage"))

tokenizer.save_pretrained(out)
shutil.copy(source / "config.json", out / "config.json")

# The same answer from both, on made-up sentences.
checks = ["Agathe Mühlenkamp wegen der Hecke anrufen",
          "Bei Fragen wenden Sie sich an Herrn Kessler.",
          "Thorsten Wägele, Hauptstraße 3, 70173 Stuttgart"]
agree = total = 0
for text in checks:
    enc = tokenizer(text, padding="max_length", max_length=LENGTH, truncation=True, return_tensors="pt")
    with torch.no_grad():
        want = Logits(model)(enc["input_ids"], enc["attention_mask"]).numpy().argmax(-1)[0]
    got = mlmodel.predict({"input_ids": enc["input_ids"].numpy().astype(np.int32),
                           "attention_mask": enc["attention_mask"].numpy().astype(np.int32)})["logits"].argmax(-1)[0]
    n = int(enc["attention_mask"].sum())
    agree += int((want[:n] == got[:n]).sum())
    total += n
print(json.dumps({"saved": str(out), "length": LENGTH, "torch and Core ML agree": f"{agree} of {total} tokens"}))
