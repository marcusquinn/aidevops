# DSPy Integration Guide

## 🎯 **Overview**

DSPy (Declarative Self-improving Python) is a framework for algorithmically optimizing LM prompts and weights. This integration provides seamless access to DSPy's powerful prompt optimization capabilities within the AI DevOps Framework.

## 🚀 **Quick Start**

### **Prerequisites**

- Python 3.8+ installed
- Virtual environment support
- OpenAI API key (or other LLM provider)

### **Installation**

```bash
# Install DSPy dependencies
./providers/dspy-helper.sh install

# Test installation
./providers/dspy-helper.sh test
```

### **Configuration**

1. **Copy configuration template:**
   ```bash
   cp configs/dspy-config.json.txt configs/dspy-config.json
   ```

2. **Edit configuration:**
   ```bash
   # Add your API keys and customize settings
   nano configs/dspy-config.json
   ```

3. **Set environment variables (if not already set):**
   ```bash
   # DSPy automatically uses your terminal session's API keys
   export OPENAI_API_KEY="your-api-key-here"
   export ANTHROPIC_API_KEY="your-anthropic-key-here"

   # Check current environment
   echo $OPENAI_API_KEY
   ```

   **Note**: DSPy prioritizes environment variables over config file values, so your existing terminal session API keys will be used automatically!

## 📁 **Project Structure**

```
aidevops/
├── providers/dspy-helper.sh          # DSPy management script
├── configs/dspy-config.json          # DSPy configuration
├── python-env/dspy-env/              # Python virtual environment
├── data/dspy/                        # DSPy projects and datasets
├── logs/                             # DSPy logs
└── requirements.txt                  # Python dependencies
```

## 🛠️ **Usage**

### **Initialize New Project**

```bash
# Create a new DSPy project
./providers/dspy-helper.sh init my-chatbot

# Navigate to project directory
cd data/dspy/my-chatbot
```

### **Basic DSPy Example**

```python
import dspy
import os

# Configure DSPy with OpenAI
lm = dspy.OpenAI(model="gpt-3.5-turbo", api_key=os.getenv("OPENAI_API_KEY"))
dspy.settings.configure(lm=lm)

# Define a signature
class BasicQA(dspy.Signature):
    """Answer questions with helpful, accurate responses."""
    question = dspy.InputField()
    answer = dspy.OutputField(desc="A helpful and accurate answer")

# Create a module
class QAModule(dspy.Module):
    def __init__(self):
        super().__init__()
        self.generate_answer = dspy.ChainOfThought(BasicQA)
    
    def forward(self, question):
        return self.generate_answer(question=question)

# Use the module
qa = QAModule()
result = qa(question="What is DSPy?")
print(result.answer)
```

### **Optimization Example**

```python
import dspy
from dspy.teleprompt import BootstrapFewShot

# Define training data
trainset = [
    dspy.Example(question="What is AI?", answer="Artificial Intelligence..."),
    dspy.Example(question="How does ML work?", answer="Machine Learning..."),
    # Add more examples
]

# Create and compile optimizer
teleprompter = BootstrapFewShot(metric=dspy.evaluate.answer_exact_match)
compiled_qa = teleprompter.compile(QAModule(), trainset=trainset)

# Use optimized module
result = compiled_qa(question="Explain neural networks")
```

## 🔧 **Configuration Options**

### **Language Models**

```json
{
  "language_models": {
    "providers": {
      "openai": {
        "api_key": "YOUR_OPENAI_API_KEY",
        "models": {
          "gpt-4": "gpt-4",
          "gpt-3.5-turbo": "gpt-3.5-turbo"
        }
      },
      "anthropic": {
        "api_key": "YOUR_ANTHROPIC_API_KEY",
        "models": {
          "claude-3-sonnet": "claude-3-sonnet-20240229"
        }
      }
    }
  }
}
```

### **Optimization Settings**

```json
{
  "optimization": {
    "optimizers": {
      "BootstrapFewShot": {
        "max_bootstrapped_demos": 4,
        "max_labeled_demos": 16
      },
      "COPRO": {
        "metric": "accuracy",
        "breadth": 10,
        "depth": 3
      }
    }
  }
}
```

## 📊 **Available Optimizers**

### **BootstrapFewShot**
- **Purpose**: Automatically generate few-shot examples
- **Best for**: General prompt optimization
- **Configuration**: `max_bootstrapped_demos`, `max_labeled_demos`

### **COPRO (Coordinate Ascent)**
- **Purpose**: Iterative prompt optimization
- **Best for**: Complex reasoning tasks
- **Configuration**: `metric`, `breadth`, `depth`

### **MIPRO (Multi-Prompt Optimization)**
- **Purpose**: Multi-stage prompt optimization
- **Best for**: Multi-step reasoning
- **Configuration**: `metric`, `num_candidates`

## 🎯 **Best Practices**

### **1. Start Simple**
```python
# Begin with basic signatures
class SimpleQA(dspy.Signature):
    question = dspy.InputField()
    answer = dspy.OutputField()
```

### **2. Use Quality Training Data**
```python
# Provide diverse, high-quality examples
trainset = [
    dspy.Example(question="...", answer="...").with_inputs('question'),
    # More examples with clear input/output patterns
]
```

### **3. Choose Appropriate Metrics**
```python
# Define custom metrics for your use case
def custom_metric(example, pred, trace=None):
    return example.answer.lower() in pred.answer.lower()
```

### **4. Iterate and Refine**
```python
# Test different optimizers and configurations
optimizers = [
    BootstrapFewShot(metric=custom_metric),
    COPRO(metric=custom_metric, breadth=5),
]
```

## 🔍 **Troubleshooting**

### **Common Issues**

1. **Import Errors**
   ```bash
   # Ensure virtual environment is activated
   source python-env/dspy-env/bin/activate
   ```

2. **API Key Issues**
   ```bash
   # Check environment variables
   echo $OPENAI_API_KEY
   ```

3. **Memory Issues**
   ```python
   # Reduce batch sizes for large datasets
   dspy.settings.configure(lm=lm, max_tokens=1000)
   ```

## 📚 **Additional Resources**

- [DSPy Documentation](https://dspy-docs.vercel.app/)
- [DSPy GitHub Repository](https://github.com/stanfordnlp/dspy)
- [DSPy Paper](https://arxiv.org/abs/2310.03714)
- [AI DevOps Framework Documentation](../README.md)

## 🤝 **Integration with AI DevOps**

DSPy integrates seamlessly with other AI DevOps Framework components:

- **Agno Integration**: Use DSPy-optimized prompts in Agno agents
- **Quality Control**: Optimize prompts for better code quality analysis
- **Documentation**: Generate optimized prompts for documentation tasks
- **Server Management**: Create optimized prompts for infrastructure tasks
