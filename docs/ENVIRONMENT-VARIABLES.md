# Environment Variables Integration

## ✅ **Automatic API Key Detection**

Both DSPy and DSPyGround are configured to **automatically use your terminal session's API keys**. No additional configuration needed!

### **Current Environment**
Your terminal session has these API keys available:
- ✅ `OPENAI_API_KEY` - Detected and ready to use

### **How It Works**

#### **DSPy Integration**
DSPy uses this priority order:
1. **Environment variables** (your terminal session) - **HIGHEST PRIORITY**
2. Configuration file values - fallback only

```python
# DSPy automatically checks environment first
api_key = os.getenv("OPENAI_API_KEY", config_fallback)
lm = dspy.LM(model="openai/gpt-3.5-turbo", api_key=api_key)
```

#### **DSPyGround Integration**
DSPyGround uses `.env` files that reference your environment:

```bash
# .env file automatically uses your terminal session variables
OPENAI_API_KEY=${OPENAI_API_KEY}  # References your existing key
```

## 🚀 **Quick Test**

### **Test DSPy with Your API Key**
```bash
cd data/dspy/test-project
source ../../../python-env/dspy-env/bin/activate
python3 main.py
```

### **Test DSPyGround with Your API Key**
```bash
cd data/dspyground/test-agent
# Your OPENAI_API_KEY is automatically available
node -e "console.log('API Key:', process.env.OPENAI_API_KEY?.slice(0,10) + '...')"
```

## 🔧 **Supported Environment Variables**

### **OpenAI**
- `OPENAI_API_KEY` - ✅ **Currently set in your environment**
- `OPENAI_BASE_URL` - Custom endpoint (optional)

### **Anthropic**
- `ANTHROPIC_API_KEY` - For Claude models
- `ANTHROPIC_BASE_URL` - Custom endpoint (optional)

### **Other Providers**
- `AI_GATEWAY_API_KEY` - For DSPyGround AI Gateway
- `GOOGLE_API_KEY` - For Gemini models
- `AZURE_OPENAI_API_KEY` - For Azure OpenAI

## 📋 **Configuration Priority**

Both tools follow this priority order:

1. **Environment Variables** (your terminal session)
2. `.env` files (project-specific)
3. Configuration files (fallback)
4. Default values (last resort)

## ✨ **Benefits**

### **Security**
- API keys stay in your secure environment
- No need to store keys in config files
- Consistent across all projects

### **Convenience**
- Works immediately with your existing setup
- No additional configuration required
- Same keys work for all AI tools

### **Flexibility**
- Override per-project with `.env` files
- Fallback to config files if needed
- Easy switching between different keys

## 🎯 **Quick Start Commands**

Since your `OPENAI_API_KEY` is already set, you can immediately:

```bash
# Test DSPy
./providers/dspy-helper.sh test

# Create and run DSPy project
./providers/dspy-helper.sh init my-bot
cd data/dspy/my-bot
source ../../../python-env/dspy-env/bin/activate
python3 main.py

# Create DSPyGround project
./providers/dspyground-helper.sh init my-agent
cd data/dspyground/my-agent
# Add AI_GATEWAY_API_KEY to .env if using AI Gateway
# Otherwise, your OPENAI_API_KEY works directly
```

## 🔍 **Troubleshooting**

### **Check Your Environment**
```bash
# Verify API keys are set
env | grep -E "(OPENAI|ANTHROPIC|CLAUDE)_API_KEY"

# Test API key format
echo $OPENAI_API_KEY | grep -E "^sk-"
```

### **Test API Connectivity**
```bash
# Test OpenAI API
curl -H "Authorization: Bearer $OPENAI_API_KEY" \
     https://api.openai.com/v1/models | head -20
```

### **Common Issues**
1. **API Key Not Found**: Check `echo $OPENAI_API_KEY`
2. **Wrong Format**: OpenAI keys start with `sk-`
3. **Permissions**: Ensure key has required permissions
4. **Rate Limits**: Check API usage limits

## 🎉 **Ready to Use!**

Your environment is already configured! Both DSPy and DSPyGround will automatically use your existing `OPENAI_API_KEY` without any additional setup.
