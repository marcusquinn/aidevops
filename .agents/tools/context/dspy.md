---
description: DSPy framework for programmatic LLM optimization
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# DSPy Integration Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- DSPy: Framework for algorithmically optimizing LLM prompts and weights
- Requires: Python 3.8+, OpenAI/Anthropic API key
- Helper: `./.agents/scripts/dspy-helper.sh install|test|init [project]`
- Config: `configs/dspy-config.json` (copy from .txt template)
- Projects: `data/dspy/[project-name]/`
- Virtual env: `python-env/dspy-env/`
- Key classes: Signature (define I/O), Module (logic), ChainOfThought (reasoning)
- Optimizers: BootstrapFewShot (few-shot), COPRO (iterative), MIPRO (multi-stage)
- API keys: Uses env vars `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`

<!-- AI-CONTEXT-END -->

## Setup

```bash
# Install and verify
./.agents/scripts/dspy-helper.sh install
./.agents/scripts/dspy-helper.sh test

# Configure
cp configs/dspy-config.json.txt configs/dspy-config.json
# Edit configs/dspy-config.json with API keys and settings

# DSPy uses env vars (OPENAI_API_KEY, ANTHROPIC_API_KEY) over config file values
```

## Project Structure

```text
aidevops/
├── .agents/scripts/dspy-helper.sh    # DSPy management script
├── configs/dspy-config.json          # DSPy configuration
├── python-env/dspy-env/              # Python virtual environment
├── data/dspy/                        # DSPy projects and datasets
├── logs/                             # DSPy logs
└── requirements.txt                  # Python dependencies
```

## Usage

```bash
# Create a new project
./.agents/scripts/dspy-helper.sh init my-chatbot
cd data/dspy/my-chatbot
```

### Basic Example

```python
import dspy
import os

lm = dspy.OpenAI(model="gpt-3.5-turbo", api_key=os.getenv("OPENAI_API_KEY"))
dspy.settings.configure(lm=lm)

class BasicQA(dspy.Signature):
    """Answer questions with helpful, accurate responses."""
    question = dspy.InputField()
    answer = dspy.OutputField(desc="A helpful and accurate answer")

class QAModule(dspy.Module):
    def __init__(self):
        super().__init__()
        self.generate_answer = dspy.ChainOfThought(BasicQA)

    def forward(self, question):
        return self.generate_answer(question=question)

qa = QAModule()
result = qa(question="What is DSPy?")
print(result.answer)
```

### Optimization Example

```python
from dspy.teleprompt import BootstrapFewShot

trainset = [
    dspy.Example(question="What is AI?", answer="Artificial Intelligence..."),
    dspy.Example(question="How does ML work?", answer="Machine Learning..."),
]

teleprompter = BootstrapFewShot(metric=dspy.evaluate.answer_exact_match)
compiled_qa = teleprompter.compile(QAModule(), trainset=trainset)
result = compiled_qa(question="Explain neural networks")
```

## Optimizers

| Optimizer | Purpose | Best for | Key config |
|-----------|---------|----------|------------|
| BootstrapFewShot | Auto-generate few-shot examples | General prompt optimization | `max_bootstrapped_demos`, `max_labeled_demos` |
| COPRO | Iterative coordinate ascent | Complex reasoning tasks | `metric`, `breadth`, `depth` |
| MIPRO | Multi-stage optimization | Multi-step reasoning | `metric`, `num_candidates` |

## Configuration

Language model providers and optimization settings are configured in `configs/dspy-config.json`. Supported providers: `openai` (gpt-4, gpt-3.5-turbo), `anthropic` (claude-sonnet). See the `.json.txt` template for the full schema.

## Best Practices

1. **Start simple** -- begin with basic Signatures before adding ChainOfThought or optimization
2. **Quality training data** -- use diverse examples with `.with_inputs('question')` for clear I/O patterns
3. **Custom metrics** -- define metrics matching your use case (e.g., `example.answer.lower() in pred.answer.lower()`)
4. **Iterate** -- test multiple optimizers (BootstrapFewShot, COPRO) with different configurations

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Import errors | Activate venv: `source python-env/dspy-env/bin/activate` |
| API key issues | Verify env vars are set: `[[ -n "$OPENAI_API_KEY" ]] && echo "OPENAI_API_KEY is set" || echo "OPENAI_API_KEY is missing"` |
| Memory issues | Reduce batch sizes: `dspy.settings.configure(lm=lm, max_tokens=1000)` |

## Resources

- [DSPy Documentation](https://dspy-docs.vercel.app/)
- [DSPy GitHub](https://github.com/stanfordnlp/dspy)
- [DSPy Paper](https://arxiv.org/abs/2310.03714)
