---
description: Prompt optimization using DSPy and DSPyGround
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

# Prompt Optimization with DSPy & DSPyGround

<!-- AI-CONTEXT-START -->

## Quick Reference

- **DSPy**: Programmatic prompt optimization framework
- **DSPyGround**: Visual playground for interactive prompt refinement
- **Workflow**: Bootstrap → Refine → Collect Samples → Optimize → Deploy
- **Optimizers**: BootstrapFewShot (start here) → MIPRO (complex cases)
- **Metrics**: Technical accuracy (1.0), security awareness (0.9), actionability (0.8), completeness (0.7)
- **Schedule**: Week 1 Foundation → Week 2 Refinement → Week 3 Specialization → Quarterly re-optimization
- **Integration**: Export optimized prompts to provider scripts, quality workflows; CI/CD for automated re-optimization

<!-- AI-CONTEXT-END -->

## Workflow

| Phase | Steps |
|-------|-------|
| **1. DSPyGround** | Bootstrap basic prompt → interactive refinement → collect 50+ samples (positive + negative) |
| **2. DSPy** | Export samples → convert to training format → apply optimizers → compare metrics → deploy |
| **3. Iterate** | Monitor → collect edge cases → re-optimize → A/B test → measure impact |

**Schedule:**

| Phase | Actions |
|-------|---------|
| **Week 1** | Create basic prompts, collect 50+ samples, run initial GEPA optimization, deploy |
| **Week 2** | Monitor real-world performance, collect failures, add negative examples, re-optimize |
| **Week 3** | Create domain-specific variants, A/B test, measure business impact |
| **Ongoing** | Quarterly re-optimization, adapt to new requirements, integrate user feedback |

## Practical Example: DevOps Assistant

**Initial prompt:**

```typescript
systemPrompt: `You are a DevOps assistant. Help with server management.`
```

**Refined prompt (after DSPyGround):**

```typescript
systemPrompt: `You are an expert DevOps engineer with 10+ years of experience.

Your expertise includes:
- Infrastructure automation and configuration management
- CI/CD pipeline design and optimization
- Container orchestration with Docker and Kubernetes
- Cloud platform management (AWS, Azure, GCP)
- Monitoring, logging, and observability
- Security best practices and compliance

Guidelines:
- Provide specific, actionable solutions with commands and configurations
- Explain potential risks and mitigation strategies
- Ask clarifying questions when requirements are unclear

Always prioritize security, reliability, and maintainability.`
```

**DSPy optimization:**

```python
import dspy
from dspy.teleprompt import BootstrapFewShot, MIPRO

class DevOpsAssistant(dspy.Signature):
    """Expert DevOps assistance with practical, secure solutions."""
    query = dspy.InputField(desc="DevOps question or problem")
    solution = dspy.OutputField(desc="Detailed, actionable solution")

class DevOpsModule(dspy.Module):
    def __init__(self):
        super().__init__()
        self.generate_solution = dspy.ChainOfThought(DevOpsAssistant)

    def forward(self, query):
        return self.generate_solution(query=query)

trainset = [
    dspy.Example(
        query="How do I deploy a Node.js app with zero downtime?",
        solution="Use blue-green deployment with load balancer..."
    ),
    # More examples from DSPyGround
]

teleprompter = BootstrapFewShot(metric=devops_accuracy_metric)
optimized_assistant = teleprompter.compile(DevOpsModule(), trainset=trainset)

# For more complex optimization:
# teleprompter = MIPRO(metric=metric, num_candidates=20, init_temperature=1.0)
```

## Configuration & Metrics

**DSPyGround config:**

```typescript
export default {
  systemPrompt: `...`,  // see refined prompt above

  tools: {
    analyzeCode: tool({
      description: 'Analyze code for issues',
      parameters: z.object({ code: z.string(), language: z.string() }),
      execute: async ({ code, language }) => analyzeCodeQuality(code, language),
    }),
  },

  preferences: {
    selectedMetrics: ['accuracy', 'tone', 'efficiency'],
    batchSize: 5,
    numRollouts: 15,
  }
}
```

**Metric functions:**

```python
def devops_accuracy_metric(example, pred, trace=None):
    security_score = check_security_mentions(pred.solution)
    technical_score = verify_technical_details(pred.solution, example.query)
    actionability_score = assess_actionability(pred.solution)
    return (security_score + technical_score + actionability_score) / 3

def code_review_quality_metric(example, pred, trace=None):
    issue_detection = check_issue_detection(pred.review, example.code)
    suggestion_quality = evaluate_suggestions(pred.review)
    tone_score = assess_constructive_tone(pred.review)
    return (issue_detection + suggestion_quality + tone_score) / 3
```

**DSPyGround metric dimensions:**

```typescript
metricsPrompt: {
  evaluation_instructions: `Evaluate DevOps AI assistant responses across:
  - Technical accuracy and completeness
  - Security awareness and best practices
  - Clarity and actionability
  - Appropriate level of detail`,

  dimensions: {
    technical_accuracy: { weight: 1.0 },
    security_awareness: { weight: 0.9 },
    actionability:      { weight: 0.8 },
    completeness:       { weight: 0.7 }
  }
}
```

## Best Practices

**Samples:** Diverse scenarios, real-world quality, balanced positive/negative, preserve context.

**Optimization:** Start with BootstrapFewShot → MIPRO for complex cases. Measure multiple metrics. Validate on held-out sets.

**Deployment:** Gradual rollout → monitor closely → maintain rollback versions → collect feedback for next iteration. Monitor/alert for performance regression.
