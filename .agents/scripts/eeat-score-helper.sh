#!/bin/bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153

# E-E-A-T Score Helper Script
# Content quality scoring using Google's E-E-A-T framework
#
# Usage: ./eeat-score-helper.sh [command] [input] [options]
# Commands:
#   analyze     - Analyze crawled pages from site-crawler output
#   score       - Score a single URL
#   batch       - Batch analyze URLs from a file
#   report      - Generate spreadsheet from existing scores
#   status      - Check dependencies and configuration
#   help        - Show this help message
#
# Author: AI DevOps Framework
# Version: 1.0.0
# License: MIT

set -euo pipefail

# Colors for output
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m'

# Constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
readonly SCRIPT_DIR
readonly CONFIG_DIR="${HOME}/.config/aidevops"
readonly CONFIG_FILE="${CONFIG_DIR}/eeat-score.json"
readonly DEFAULT_OUTPUT_DIR="${HOME}/Downloads"

# Default configuration
LLM_PROVIDER="openai"
LLM_MODEL="gpt-4o"
TEMPERATURE="0.3"
MAX_TOKENS="500"
CONCURRENT_REQUESTS=3
OUTPUT_FORMAT="xlsx"
INCLUDE_REASONING=true

# Weights for overall score calculation
WEIGHT_AUTHORSHIP=0.15
WEIGHT_CITATION=0.15
WEIGHT_EFFORT=0.15
WEIGHT_ORIGINALITY=0.15
WEIGHT_INTENT=0.15
WEIGHT_SUBJECTIVE=0.15
WEIGHT_WRITING=0.10

# Print functions
print_success() {
    local message="$1"
    echo -e "${GREEN}[OK] $message${NC}"
    return 0
}

print_info() {
    local message="$1"
    echo -e "${BLUE}[INFO] $message${NC}"
    return 0
}

print_warning() {
    local message="$1"
    echo -e "${YELLOW}[WARN] $message${NC}"
    return 0
}

print_error() {
    local message="$1"
    echo -e "${RED}[ERROR] $message${NC}"
    return 0
}

print_header() {
    local message="$1"
    echo -e "${PURPLE}=== $message ===${NC}"
    return 0
}

# Load configuration
load_config() {
    if [[ -f "$CONFIG_FILE" ]] && command -v jq &> /dev/null; then
        LLM_PROVIDER=$(jq -r '.llm_provider // "openai"' "$CONFIG_FILE")
        LLM_MODEL=$(jq -r '.llm_model // "gpt-4o"' "$CONFIG_FILE")
        TEMPERATURE=$(jq -r '.temperature // 0.3' "$CONFIG_FILE")
        MAX_TOKENS=$(jq -r '.max_tokens // 500' "$CONFIG_FILE")
        CONCURRENT_REQUESTS=$(jq -r '.concurrent_requests // 3' "$CONFIG_FILE")
        OUTPUT_FORMAT=$(jq -r '.output_format // "xlsx"' "$CONFIG_FILE")
        INCLUDE_REASONING=$(jq -r '.include_reasoning // true' "$CONFIG_FILE")
        
        # Load weights
        WEIGHT_AUTHORSHIP=$(jq -r '.weights.authorship // 0.15' "$CONFIG_FILE")
        WEIGHT_CITATION=$(jq -r '.weights.citation // 0.15' "$CONFIG_FILE")
        WEIGHT_EFFORT=$(jq -r '.weights.effort // 0.15' "$CONFIG_FILE")
        WEIGHT_ORIGINALITY=$(jq -r '.weights.originality // 0.15' "$CONFIG_FILE")
        WEIGHT_INTENT=$(jq -r '.weights.intent // 0.15' "$CONFIG_FILE")
        WEIGHT_SUBJECTIVE=$(jq -r '.weights.subjective // 0.15' "$CONFIG_FILE")
        WEIGHT_WRITING=$(jq -r '.weights.writing // 0.10' "$CONFIG_FILE")
    fi
    return 0
}

# Check dependencies
check_dependencies() {
    local missing=()
    
    if ! command -v curl &> /dev/null; then
        missing+=("curl")
    fi
    
    if ! command -v jq &> /dev/null; then
        missing+=("jq")
    fi
    
    if ! command -v python3 &> /dev/null; then
        missing+=("python3")
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        print_error "Missing dependencies: ${missing[*]}"
        print_info "Install with: brew install ${missing[*]}"
        return 1
    fi
    
    return 0
}

# Check API key
check_api_key() {
    if [[ "$LLM_PROVIDER" == "openai" ]]; then
        if [[ -z "${OPENAI_API_KEY:-}" ]]; then
            print_error "OPENAI_API_KEY environment variable not set"
            print_info "Set with: export OPENAI_API_KEY='sk-...'"
            return 1
        fi
    elif [[ "$LLM_PROVIDER" == "anthropic" ]]; then
        if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
            print_error "ANTHROPIC_API_KEY environment variable not set"
            return 1
        fi
    fi
    return 0
}

# Extract domain from URL
get_domain() {
    local url="$1"
    echo "$url" | sed -E 's|^https?://||' | sed -E 's|/.*||' | sed -E 's|:.*||'
}

# Create output directory structure
create_output_dir() {
    local domain="$1"
    local output_base="${2:-$DEFAULT_OUTPUT_DIR}"
    local timestamp
    timestamp=$(date +%Y-%m-%d_%H%M%S)
    
    local output_dir="${output_base}/${domain}/${timestamp}"
    mkdir -p "$output_dir"
    
    # Update _latest symlink
    local latest_link="${output_base}/${domain}/_latest"
    rm -f "$latest_link"
    ln -sf "$timestamp" "$latest_link"
    
    echo "$output_dir"
    return 0
}

# Generate Python E-E-A-T analyzer script
generate_analyzer_script() {
    cat << 'PYTHON_SCRIPT'
#!/usr/bin/env python3
"""
E-E-A-T Score Analyzer
Evaluates content quality using Google's E-E-A-T framework
"""

import asyncio
import json
import csv
import sys
import os
from datetime import datetime
from pathlib import Path
from dataclasses import dataclass, field, asdict
from typing import Optional, List, Dict
import aiohttp
from bs4 import BeautifulSoup

try:
    import openpyxl
    from openpyxl.styles import Font, PatternFill, Alignment
    HAS_OPENPYXL = True
except ImportError:
    HAS_OPENPYXL = False

# E-E-A-T Prompts
PROMPTS = {
    "authorship_reasoning": """You are evaluating Authorship & Expertise for this page. Analyze and explain in 3-4 sentences:
- Is there a clear AUTHOR? If yes, who and what credentials?
- Can you identify the PUBLISHER (who owns/operates the site)?
- Is this a "Disconnected Entity" (anonymous, untraceable) or "Connected Entity" (verifiable)?
- Do they demonstrate RELEVANT EXPERTISE for this topic?
Be specific with names, credentials, evidence from the page.""",

    "authorship_score": """You are evaluating Authorship & Expertise (isAuthor criterion).
CRITICAL: A "Disconnected Entity" is one where you CANNOT find "who owns and operates" the site.
Evaluate:
- Is there a clear author byline linking to a detailed biography?
- Does the About page clearly identify the company or person responsible?
- Is this entity VERIFIABLE and ACCOUNTABLE?
- Do they demonstrate RELEVANT EXPERTISE for this topic?
Score 1-10:
1-3 = DISCONNECTED ENTITY: No clear author, anonymous, untraceable
4-6 = Partial attribution, but weak verifiability or unclear credentials
7-10 = CONNECTED ENTITY: Clear author with detailed bio, verifiable expertise
Return ONLY the number.""",

    "citation_reasoning": """You are evaluating Citation Quality for this page. Analyze and explain in 3-4 sentences:
- Does the page make SPECIFIC FACTUAL CLAIMS?
- Are those claims SUBSTANTIATED with citations?
- QUALITY assessment: Primary sources (studies, official docs) or secondary/low-quality?
- Or are claims unsupported?
Be specific with examples of claims and their (lack of) citations.""",

    "citation_score": """You are evaluating Citation Quality & Substantiation.
Does this content BACK UP its claims with high-quality sources?
Analyze:
- Does the page make SPECIFIC FACTUAL CLAIMS?
- Are those claims SUBSTANTIATED with citations/links?
- QUALITY of sources: Primary sources (studies, legal docs, official data)?
Score 1-10:
1-3 = LOW: Bold claims with NO citations, or only low-quality links
4-6 = MODERATE: Some citations but mediocre quality
7-10 = HIGH: Core claims substantiated with primary sources
Return ONLY the number.""",

    "effort_reasoning": """You are evaluating Content Effort for this page. Analyze and explain in 3-4 sentences:
- How DIFFICULT would it be to REPLICATE this content? (time, cost, expertise)
- Does the page "SHOW ITS WORK"? Is the creation process transparent?
- What evidence of high/low effort? (original research, data, multimedia, depth)
- Any unique elements that required significant resources?
Be specific with examples from the page.""",

    "effort_score": """You are evaluating Content Effort.
Assess the DEMONSTRABLE effort, expertise, and resources invested.
Key questions:
1. REPLICABILITY: How difficult would it be for a competitor to create equal content?
2. CREATION PROCESS: Does the page "show its work"?
Look for: In-depth analysis, original data, unique multimedia, transparent methodology
Score 1-10:
1-3 = LOW EFFORT: Generic, formulaic, easily replicated in hours
7-8 = HIGH EFFORT: Significant investment, hard to replicate
9-10 = EXCEPTIONAL: Original research, proprietary data, unique tools
Return ONLY the number.""",

    "originality_reasoning": """You are evaluating Content Originality for this page. Analyze and explain in 3-4 sentences:
- Does this page introduce NEW INFORMATION or a UNIQUE PERSPECTIVE?
- Or does it just REPHRASE existing knowledge from other sources?
- Is it substantively unique in phrasing, data, angle, or presentation?
- What makes it original or generic?
Be specific with examples.""",

    "originality_score": """You are evaluating Content Originality.
Does this content ADD NEW INFORMATION to the web, or just rephrase what exists?
Evaluate:
- Is the content SUBSTANTIVELY UNIQUE in phrasing, perspective, data?
- Does it introduce NEW INFORMATION or a UNIQUE ANGLE?
Red flags: Templated content, spun/paraphrased, generic information
Score 1-10:
1-3 = LOW ORIGINALITY: Templated, duplicated, rehashes existing knowledge
4-6 = MODERATE: Mix of original and generic elements
7-10 = HIGH ORIGINALITY: Substantively unique, adds new information
Return ONLY the number.""",

    "intent_reasoning": """You are evaluating Page Intent for this page. Analyze and explain in 3-4 sentences:
- What is this page's PRIMARY PURPOSE (the "WHY" it exists)?
- Is it HELPFUL-FIRST (created to help users) or SEARCH-FIRST (created to rank)?
- Is the intent TRANSPARENT and honest, or DECEPTIVE?
- What evidence supports your assessment?
Be specific with examples from the content.""",

    "intent_score": """You are evaluating Page Intent.
WHY was this page created? What is its PRIMARY PURPOSE?
Determine if this is:
- HELPFUL-FIRST: Created primarily to help users/solve problems
- Or SEARCH-FIRST: Created primarily to rank in search
Red flags: Thin content for keywords, disguised affiliate, keyword stuffing
Green flags: Clear user problem solved, transparent purpose, genuine value
Score 1-10:
1-3 = DECEPTIVE/SEARCH-FIRST: Created for search traffic, deceptive intent
4-6 = UNCLEAR: Mixed signals
7-10 = TRANSPARENT/HELPFUL-FIRST: Created to help people, honest purpose
Return ONLY the number.""",

    "subjective_reasoning": """You are a brutally honest content critic. Be direct, not nice. Evaluate this content for:
boring sections, confusing parts, unbelievable claims, unclear audience pain point,
missing culprit identification, sections that could be condensed, lack of proprietary insights.
CRITICAL: Provide EXACTLY 2-3 sentences summarizing the main weaknesses.
NO bullet points. NO lists. NO section headers. NO more than 3 sentences.""",

    "subjective_score": """You are a brutally honest content critic evaluating subjective quality.
CRITICAL: Put on your most critical hat. Don't be nice. High standards only.
Evaluate: ENGAGEMENT (boring or compelling?), CLARITY (confusing?), CREDIBILITY (believable?),
AUDIENCE TARGETING (pain point addressed?), VALUE DENSITY (fluff or substance?)
Score 1-10:
1-3 = LOW QUALITY: Boring, confusing, unbelievable, generic advice
4-6 = MEDIOCRE: Some good parts but significant issues
7-10 = HIGH QUALITY: Compelling, clear, credible, dense value
Return ONLY the number.""",

    "writing_reasoning": """You are a writing quality analyst. Evaluate this text's linguistic quality.
Analyze: lexical diversity (vocabulary richness/repetition), readability (sentence length 15-20 words optimal),
modal verbs balance, passive voice usage, and heavy adverbs.
CRITICAL: Provide EXACTLY 2-3 sentences summarizing the main writing issues.
NO bullet points. NO lists. Maximum 150 words total.""",

    "writing_score": """You are a writing quality analyst evaluating objective linguistic metrics.
Analyze:
1. LEXICAL DIVERSITY: Rich vocabulary or repetitive?
2. READABILITY: Sentence length 15-20 words optimal, mix of easy/medium sentences
3. LINGUISTIC QUALITY: Modal verbs balanced, minimal passive voice, limited heavy adverbs
Score 1-10:
1-3 = POOR: Repetitive vocabulary, long complex sentences, excessive passive/adverbs
4-6 = AVERAGE: Some issues with readability or linguistic quality
7-10 = EXCELLENT: Rich vocabulary, optimal sentence length, active voice, concise
Return ONLY the number."""
}

@dataclass
class EEATScore:
    url: str
    authorship_score: int = 0
    authorship_reasoning: str = ""
    citation_score: int = 0
    citation_reasoning: str = ""
    effort_score: int = 0
    effort_reasoning: str = ""
    originality_score: int = 0
    originality_reasoning: str = ""
    intent_score: int = 0
    intent_reasoning: str = ""
    subjective_score: int = 0
    subjective_reasoning: str = ""
    writing_score: int = 0
    writing_reasoning: str = ""
    overall_score: float = 0.0
    grade: str = ""
    analyzed_at: str = ""

class EEATAnalyzer:
    def __init__(self, output_dir: str, provider: str = "openai", 
                 model: str = "gpt-4o", temperature: float = 0.3,
                 weights: Dict[str, float] = None):
        self.output_dir = Path(output_dir)
        self.provider = provider
        self.model = model
        self.temperature = temperature
        self.weights = weights or {
            "authorship": 0.15,
            "citation": 0.15,
            "effort": 0.15,
            "originality": 0.15,
            "intent": 0.15,
            "subjective": 0.15,
            "writing": 0.10
        }
        self.session: Optional[aiohttp.ClientSession] = None
        self.scores: List[EEATScore] = []
    
    async def fetch_page_content(self, url: str) -> str:
        """Fetch page content for analysis"""
        try:
            async with self.session.get(url, timeout=30) as response:
                if response.status == 200:
                    html = await response.text()
                    soup = BeautifulSoup(html, 'html.parser')
                    
                    # Remove script and style elements
                    for element in soup(['script', 'style', 'nav', 'footer', 'header']):
                        element.decompose()
                    
                    # Get text content
                    text = soup.get_text(separator='\n', strip=True)
                    
                    # Truncate to reasonable length for LLM
                    if len(text) > 15000:
                        text = text[:15000] + "\n[Content truncated...]"
                    
                    return text
        except Exception as e:
            print(f"Error fetching {url}: {e}")
        return ""
    
    async def call_llm(self, prompt: str, content: str) -> str:
        """Call LLM API for analysis"""
        if self.provider == "openai":
            return await self._call_openai(prompt, content)
        elif self.provider == "anthropic":
            return await self._call_anthropic(prompt, content)
        return ""
    
    async def _call_openai(self, prompt: str, content: str) -> str:
        """Call OpenAI API"""
        api_key = os.environ.get("OPENAI_API_KEY")
        if not api_key:
            raise ValueError("OPENAI_API_KEY not set")
        
        headers = {
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json"
        }
        
        payload = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": prompt},
                {"role": "user", "content": f"Analyze this content:\n\n{content}"}
            ],
            "temperature": self.temperature,
            "max_tokens": 500
        }
        
        try:
            async with self.session.post(
                "https://api.openai.com/v1/chat/completions",
                headers=headers,
                json=payload,
                timeout=60
            ) as response:
                if response.status == 200:
                    data = await response.json()
                    return data["choices"][0]["message"]["content"].strip()
                else:
                    error = await response.text()
                    print(f"OpenAI API error: {error}")
        except Exception as e:
            print(f"OpenAI API call failed: {e}")
        return ""
    
    async def _call_anthropic(self, prompt: str, content: str) -> str:
        """Call Anthropic API"""
        api_key = os.environ.get("ANTHROPIC_API_KEY")
        if not api_key:
            raise ValueError("ANTHROPIC_API_KEY not set")
        
        headers = {
            "x-api-key": api_key,
            "Content-Type": "application/json",
            "anthropic-version": "2023-06-01"
        }
        
        payload = {
            "model": self.model if "claude" in self.model else "claude-3-sonnet-20240229",
            "max_tokens": 500,
            "messages": [
                {"role": "user", "content": f"{prompt}\n\nAnalyze this content:\n\n{content}"}
            ]
        }
        
        try:
            async with self.session.post(
                "https://api.anthropic.com/v1/messages",
                headers=headers,
                json=payload,
                timeout=60
            ) as response:
                if response.status == 200:
                    data = await response.json()
                    return data["content"][0]["text"].strip()
        except Exception as e:
            print(f"Anthropic API call failed: {e}")
        return ""
    
    def parse_score(self, response: str) -> int:
        """Extract numeric score from LLM response"""
        # Try to find a number 1-10
        import re
        numbers = re.findall(r'\b([1-9]|10)\b', response)
        if numbers:
            return int(numbers[0])
        return 5  # Default to middle score
    
    def calculate_overall_score(self, score: EEATScore) -> float:
        """Calculate weighted overall score"""
        total = (
            score.authorship_score * self.weights["authorship"] +
            score.citation_score * self.weights["citation"] +
            score.effort_score * self.weights["effort"] +
            score.originality_score * self.weights["originality"] +
            score.intent_score * self.weights["intent"] +
            score.subjective_score * self.weights["subjective"] +
            score.writing_score * self.weights["writing"]
        )
        return round(total, 2)
    
    def calculate_grade(self, overall_score: float) -> str:
        """Convert score to letter grade"""
        if overall_score >= 8.0:
            return "A"
        elif overall_score >= 6.5:
            return "B"
        elif overall_score >= 5.0:
            return "C"
        elif overall_score >= 3.5:
            return "D"
        else:
            return "F"
    
    async def analyze_url(self, url: str) -> EEATScore:
        """Analyze a single URL for E-E-A-T"""
        print(f"Analyzing: {url}")
        
        score = EEATScore(url=url, analyzed_at=datetime.now().isoformat())
        
        # Fetch content
        content = await self.fetch_page_content(url)
        if not content:
            print(f"  Could not fetch content for {url}")
            return score
        
        # Analyze each criterion
        criteria = [
            ("authorship", "authorship_score", "authorship_reasoning"),
            ("citation", "citation_score", "citation_reasoning"),
            ("effort", "effort_score", "effort_reasoning"),
            ("originality", "originality_score", "originality_reasoning"),
            ("intent", "intent_score", "intent_reasoning"),
            ("subjective", "subjective_score", "subjective_reasoning"),
            ("writing", "writing_score", "writing_reasoning"),
        ]
        
        for criterion, score_attr, reasoning_attr in criteria:
            print(f"  Evaluating {criterion}...")
            
            # Get reasoning
            reasoning_prompt = PROMPTS[f"{criterion}_reasoning"]
            reasoning = await self.call_llm(reasoning_prompt, content)
            setattr(score, reasoning_attr, reasoning)
            
            # Get score
            score_prompt = PROMPTS[f"{criterion}_score"]
            score_response = await self.call_llm(score_prompt, content)
            numeric_score = self.parse_score(score_response)
            setattr(score, score_attr, numeric_score)
            
            print(f"    Score: {numeric_score}/10")
            
            # Small delay to avoid rate limits
            await asyncio.sleep(0.5)
        
        # Calculate overall score and grade
        score.overall_score = self.calculate_overall_score(score)
        score.grade = self.calculate_grade(score.overall_score)
        
        print(f"  Overall: {score.overall_score}/10 (Grade: {score.grade})")
        
        return score
    
    async def analyze_urls(self, urls: List[str]):
        """Analyze multiple URLs"""
        headers = {
            'User-Agent': 'AIDevOps-EEATAnalyzer/1.0'
        }
        
        connector = aiohttp.TCPConnector(limit=5)
        timeout = aiohttp.ClientTimeout(total=120)
        
        async with aiohttp.ClientSession(
            headers=headers,
            connector=connector,
            timeout=timeout
        ) as session:
            self.session = session
            
            for url in urls:
                score = await self.analyze_url(url)
                self.scores.append(score)
        
        return self.scores
    
    def export_csv(self, filename: str):
        """Export scores to CSV"""
        filepath = self.output_dir / filename
        
        fieldnames = [
            'url', 'overall_score', 'grade',
            'authorship_score', 'authorship_reasoning',
            'citation_score', 'citation_reasoning',
            'effort_score', 'effort_reasoning',
            'originality_score', 'originality_reasoning',
            'intent_score', 'intent_reasoning',
            'subjective_score', 'subjective_reasoning',
            'writing_score', 'writing_reasoning',
            'analyzed_at'
        ]
        
        with open(filepath, 'w', newline='', encoding='utf-8') as f:
            writer = csv.DictWriter(f, fieldnames=fieldnames)
            writer.writeheader()
            for score in self.scores:
                writer.writerow(asdict(score))
        
        print(f"Exported: {filepath}")
    
    def export_xlsx(self, filename: str):
        """Export scores to Excel with formatting"""
        if not HAS_OPENPYXL:
            print("openpyxl not installed, skipping XLSX export")
            return
        
        filepath = self.output_dir / filename
        wb = openpyxl.Workbook()
        ws = wb.active
        ws.title = "E-E-A-T Scores"
        
        # Headers
        headers = [
            'URL', 'Overall Score', 'Grade',
            'Authorship', 'Authorship Notes',
            'Citation', 'Citation Notes',
            'Effort', 'Effort Notes',
            'Originality', 'Originality Notes',
            'Intent', 'Intent Notes',
            'Subjective', 'Subjective Notes',
            'Writing', 'Writing Notes',
            'Analyzed At'
        ]
        
        # Header styling
        header_fill = PatternFill(start_color="4472C4", end_color="4472C4", fill_type="solid")
        header_font = Font(color="FFFFFF", bold=True)
        
        for col, header in enumerate(headers, 1):
            cell = ws.cell(row=1, column=col, value=header)
            cell.fill = header_fill
            cell.font = header_font
            cell.alignment = Alignment(horizontal='center')
        
        # Grade colors
        grade_colors = {
            'A': '00B050',  # Green
            'B': '92D050',  # Light green
            'C': 'FFEB9C',  # Yellow
            'D': 'FFC7CE',  # Light red
            'F': 'FF0000',  # Red
        }
        
        # Data rows
        for row_num, score in enumerate(self.scores, 2):
            ws.cell(row=row_num, column=1, value=score.url)
            ws.cell(row=row_num, column=2, value=score.overall_score)
            
            grade_cell = ws.cell(row=row_num, column=3, value=score.grade)
            if score.grade in grade_colors:
                grade_cell.fill = PatternFill(
                    start_color=grade_colors[score.grade],
                    end_color=grade_colors[score.grade],
                    fill_type="solid"
                )
            
            ws.cell(row=row_num, column=4, value=score.authorship_score)
            ws.cell(row=row_num, column=5, value=score.authorship_reasoning)
            ws.cell(row=row_num, column=6, value=score.citation_score)
            ws.cell(row=row_num, column=7, value=score.citation_reasoning)
            ws.cell(row=row_num, column=8, value=score.effort_score)
            ws.cell(row=row_num, column=9, value=score.effort_reasoning)
            ws.cell(row=row_num, column=10, value=score.originality_score)
            ws.cell(row=row_num, column=11, value=score.originality_reasoning)
            ws.cell(row=row_num, column=12, value=score.intent_score)
            ws.cell(row=row_num, column=13, value=score.intent_reasoning)
            ws.cell(row=row_num, column=14, value=score.subjective_score)
            ws.cell(row=row_num, column=15, value=score.subjective_reasoning)
            ws.cell(row=row_num, column=16, value=score.writing_score)
            ws.cell(row=row_num, column=17, value=score.writing_reasoning)
            ws.cell(row=row_num, column=18, value=score.analyzed_at)
        
        # Adjust column widths
        ws.column_dimensions['A'].width = 50
        ws.column_dimensions['B'].width = 12
        ws.column_dimensions['C'].width = 8
        for col in ['D', 'F', 'H', 'J', 'L', 'N', 'P']:
            ws.column_dimensions[col].width = 10
        for col in ['E', 'G', 'I', 'K', 'M', 'O', 'Q']:
            ws.column_dimensions[col].width = 40
        ws.column_dimensions['R'].width = 20
        
        # Freeze header row
        ws.freeze_panes = 'A2'
        
        wb.save(filepath)
        print(f"Exported: {filepath}")
    
    def export_summary(self, filename: str = "eeat-summary.json"):
        """Export summary statistics"""
        if not self.scores:
            return
        
        summary = {
            "analyzed_at": datetime.now().isoformat(),
            "total_pages": len(self.scores),
            "average_scores": {
                "overall": round(sum(s.overall_score for s in self.scores) / len(self.scores), 2),
                "authorship": round(sum(s.authorship_score for s in self.scores) / len(self.scores), 2),
                "citation": round(sum(s.citation_score for s in self.scores) / len(self.scores), 2),
                "effort": round(sum(s.effort_score for s in self.scores) / len(self.scores), 2),
                "originality": round(sum(s.originality_score for s in self.scores) / len(self.scores), 2),
                "intent": round(sum(s.intent_score for s in self.scores) / len(self.scores), 2),
                "subjective": round(sum(s.subjective_score for s in self.scores) / len(self.scores), 2),
                "writing": round(sum(s.writing_score for s in self.scores) / len(self.scores), 2),
            },
            "grade_distribution": {
                "A": sum(1 for s in self.scores if s.grade == "A"),
                "B": sum(1 for s in self.scores if s.grade == "B"),
                "C": sum(1 for s in self.scores if s.grade == "C"),
                "D": sum(1 for s in self.scores if s.grade == "D"),
                "F": sum(1 for s in self.scores if s.grade == "F"),
            },
            "weakest_areas": [],
            "strongest_areas": []
        }
        
        # Find weakest and strongest areas
        avg_scores = summary["average_scores"]
        sorted_areas = sorted(
            [(k, v) for k, v in avg_scores.items() if k != "overall"],
            key=lambda x: x[1]
        )
        summary["weakest_areas"] = [a[0] for a in sorted_areas[:2]]
        summary["strongest_areas"] = [a[0] for a in sorted_areas[-2:]]
        
        filepath = self.output_dir / filename
        with open(filepath, 'w') as f:
            json.dump(summary, f, indent=2)
        
        print(f"Exported: {filepath}")
        return summary


async def main():
    import argparse
    
    parser = argparse.ArgumentParser(description='E-E-A-T Score Analyzer')
    parser.add_argument('urls', nargs='+', help='URLs to analyze')
    parser.add_argument('--output', '-o', required=True, help='Output directory')
    parser.add_argument('--provider', default='openai', choices=['openai', 'anthropic'])
    parser.add_argument('--model', default='gpt-4o', help='LLM model to use')
    parser.add_argument('--format', '-f', choices=['csv', 'xlsx', 'all'], default='xlsx')
    parser.add_argument('--domain', help='Domain name for output files')
    
    args = parser.parse_args()
    
    # Create output directory
    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)
    
    analyzer = EEATAnalyzer(
        output_dir=str(output_dir),
        provider=args.provider,
        model=args.model
    )
    
    await analyzer.analyze_urls(args.urls)
    
    # Generate filename
    domain = args.domain or "eeat-analysis"
    timestamp = datetime.now().strftime("%Y-%m-%d")
    
    if args.format in ("xlsx", "all"):
        analyzer.export_xlsx(f"{domain}-eeat-score-{timestamp}.xlsx")
    if args.format in ("csv", "all"):
        analyzer.export_csv(f"{domain}-eeat-score-{timestamp}.csv")
    
    summary = analyzer.export_summary()
    
    print(f"\n=== E-E-A-T Analysis Summary ===")
    print(f"Pages analyzed: {summary['total_pages']}")
    print(f"Average overall score: {summary['average_scores']['overall']}/10")
    print(f"Grade distribution: A={summary['grade_distribution']['A']}, "
          f"B={summary['grade_distribution']['B']}, C={summary['grade_distribution']['C']}, "
          f"D={summary['grade_distribution']['D']}, F={summary['grade_distribution']['F']}")
    print(f"Weakest areas: {', '.join(summary['weakest_areas'])}")
    print(f"Strongest areas: {', '.join(summary['strongest_areas'])}")
    print(f"\nResults saved to: {output_dir}")


if __name__ == "__main__":
    asyncio.run(main())
PYTHON_SCRIPT
}

# Analyze crawled pages
do_analyze() {
    local input_file="$1"
    shift
    
    if [[ ! -f "$input_file" ]]; then
        print_error "Input file not found: $input_file"
        return 1
    fi
    
    # Parse options
    local output_base="$DEFAULT_OUTPUT_DIR"
    local format="$OUTPUT_FORMAT"
    local provider="$LLM_PROVIDER"
    local model="$LLM_MODEL"
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output)
                output_base="$2"
                shift 2
                ;;
            --format)
                format="$2"
                shift 2
                ;;
            --provider)
                provider="$2"
                shift 2
                ;;
            --model)
                model="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done
    
    # Extract URLs from crawl data
    local urls=()
    if [[ "$input_file" == *.json ]]; then
        # JSON format - extract URLs with status 200
        mapfile -t urls < <(jq -r '.[] | select(.status_code == 200) | .url' "$input_file" 2>/dev/null || echo "")
    elif [[ "$input_file" == *.csv ]]; then
        # CSV format - extract URLs from first column where status is 200
        mapfile -t urls < <(tail -n +2 "$input_file" | awk -F',' '$2 == "200" || $2 == 200 {gsub(/"/, "", $1); print $1}')
    fi
    
    if [[ ${#urls[@]} -eq 0 ]]; then
        print_error "No valid URLs found in input file"
        return 1
    fi
    
    print_header "E-E-A-T Score Analysis"
    print_info "Input: $input_file"
    print_info "URLs to analyze: ${#urls[@]}"
    
    # Determine domain from first URL
    local domain
    domain=$(get_domain "${urls[0]}")
    
    # Get output directory (use same as crawl data if in domain folder)
    local input_dir
    input_dir=$(dirname "$input_file")
    local output_dir
    
    if [[ "$input_dir" == *"$domain"* ]]; then
        output_dir="$input_dir"
    else
        output_dir=$(create_output_dir "$domain" "$output_base")
    fi
    
    print_info "Output: $output_dir"
    
    # Check Python dependencies
    if ! python3 -c "import aiohttp, bs4" 2>/dev/null; then
        print_warning "Installing Python dependencies..."
        pip3 install aiohttp beautifulsoup4 openpyxl --quiet
    fi
    
    # Generate and run analyzer
    local analyzer_script="/tmp/eeat_analyzer_$$.py"
    generate_analyzer_script > "$analyzer_script"
    
    # Limit to reasonable number for API costs
    local max_urls=50
    if [[ ${#urls[@]} -gt $max_urls ]]; then
        print_warning "Limiting analysis to first $max_urls URLs (of ${#urls[@]})"
        urls=("${urls[@]:0:$max_urls}")
    fi
    
    python3 "$analyzer_script" "${urls[@]}" \
        --output "$output_dir" \
        --provider "$provider" \
        --model "$model" \
        --format "$format" \
        --domain "$domain"
    
    rm -f "$analyzer_script"
    
    print_success "E-E-A-T analysis complete!"
    print_info "Results: $output_dir"
    
    return 0
}

# Score single URL
do_score() {
    local url="$1"
    shift
    
    local verbose=false
    local output_base="$DEFAULT_OUTPUT_DIR"
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --verbose|-v)
                verbose=true
                shift
                ;;
            --output)
                output_base="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done
    
    local domain
    domain=$(get_domain "$url")
    local output_dir
    output_dir=$(create_output_dir "$domain" "$output_base")
    
    print_header "E-E-A-T Score Analysis"
    print_info "URL: $url"
    
    # Check Python dependencies
    if ! python3 -c "import aiohttp, bs4" 2>/dev/null; then
        print_warning "Installing Python dependencies..."
        pip3 install aiohttp beautifulsoup4 openpyxl --quiet
    fi
    
    local analyzer_script="/tmp/eeat_analyzer_$$.py"
    generate_analyzer_script > "$analyzer_script"
    
    python3 "$analyzer_script" "$url" \
        --output "$output_dir" \
        --provider "$LLM_PROVIDER" \
        --model "$LLM_MODEL" \
        --format "all" \
        --domain "$domain"
    
    rm -f "$analyzer_script"
    
    print_success "Analysis complete!"
    print_info "Results: $output_dir"
    
    return 0
}

# Batch analyze URLs from file
do_batch() {
    local urls_file="$1"
    shift
    
    if [[ ! -f "$urls_file" ]]; then
        print_error "URLs file not found: $urls_file"
        return 1
    fi
    
    local urls=()
    while IFS= read -r url; do
        [[ -n "$url" && ! "$url" =~ ^# ]] && urls+=("$url")
    done < "$urls_file"
    
    if [[ ${#urls[@]} -eq 0 ]]; then
        print_error "No URLs found in file"
        return 1
    fi
    
    local output_base="$DEFAULT_OUTPUT_DIR"
    local format="$OUTPUT_FORMAT"
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output)
                output_base="$2"
                shift 2
                ;;
            --format)
                format="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done
    
    local domain
    domain=$(get_domain "${urls[0]}")
    local output_dir
    output_dir=$(create_output_dir "$domain" "$output_base")
    
    print_header "E-E-A-T Batch Analysis"
    print_info "URLs: ${#urls[@]}"
    print_info "Output: $output_dir"
    
    # Check Python dependencies
    if ! python3 -c "import aiohttp, bs4" 2>/dev/null; then
        print_warning "Installing Python dependencies..."
        pip3 install aiohttp beautifulsoup4 openpyxl --quiet
    fi
    
    local analyzer_script="/tmp/eeat_analyzer_$$.py"
    generate_analyzer_script > "$analyzer_script"
    
    python3 "$analyzer_script" "${urls[@]}" \
        --output "$output_dir" \
        --provider "$LLM_PROVIDER" \
        --model "$LLM_MODEL" \
        --format "$format" \
        --domain "$domain"
    
    rm -f "$analyzer_script"
    
    print_success "Batch analysis complete!"
    print_info "Results: $output_dir"
    
    return 0
}

# Generate report from existing scores
do_report() {
    local scores_file="$1"
    shift
    
    if [[ ! -f "$scores_file" ]]; then
        print_error "Scores file not found: $scores_file"
        return 1
    fi
    
    print_header "Generating E-E-A-T Report"
    print_info "Input: $scores_file"
    
    # For now, just display summary from JSON
    if [[ "$scores_file" == *.json ]]; then
        if command -v jq &> /dev/null; then
            jq '.' "$scores_file"
        else
            cat "$scores_file"
        fi
    fi
    
    return 0
}

# Check status
check_status() {
    print_header "E-E-A-T Score Helper Status"
    
    # Check dependencies
    print_info "Checking dependencies..."
    
    if command -v curl &> /dev/null; then
        print_success "curl: installed"
    else
        print_error "curl: not installed"
    fi
    
    if command -v jq &> /dev/null; then
        print_success "jq: installed"
    else
        print_error "jq: not installed"
    fi
    
    if command -v python3 &> /dev/null; then
        print_success "python3: installed"
        
        if python3 -c "import aiohttp" 2>/dev/null; then
            print_success "  aiohttp: installed"
        else
            print_warning "  aiohttp: not installed (pip3 install aiohttp)"
        fi
        
        if python3 -c "import bs4" 2>/dev/null; then
            print_success "  beautifulsoup4: installed"
        else
            print_warning "  beautifulsoup4: not installed"
        fi
        
        if python3 -c "import openpyxl" 2>/dev/null; then
            print_success "  openpyxl: installed"
        else
            print_warning "  openpyxl: not installed"
        fi
    else
        print_error "python3: not installed"
    fi
    
    # Check API keys
    print_info "Checking API keys..."
    
    if [[ -n "${OPENAI_API_KEY:-}" ]]; then
        print_success "OPENAI_API_KEY: set"
    else
        print_warning "OPENAI_API_KEY: not set"
    fi
    
    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        print_success "ANTHROPIC_API_KEY: set"
    else
        print_info "ANTHROPIC_API_KEY: not set (optional)"
    fi
    
    # Check config
    if [[ -f "$CONFIG_FILE" ]]; then
        print_success "Config: $CONFIG_FILE"
    else
        print_info "Config: using defaults"
    fi
    
    return 0
}

# Show help
show_help() {
    cat << 'EOF'
E-E-A-T Score Helper - Content Quality Analysis

Usage: eeat-score-helper.sh [command] [input] [options]

Commands:
  analyze <crawl-data>  Analyze pages from site-crawler output
  score <url>           Score a single URL
  batch <urls-file>     Batch analyze URLs from a file
  report <scores-file>  Generate report from existing scores
  status                Check dependencies and configuration
  help                  Show this help message

Options:
  --output <dir>        Output directory (default: ~/Downloads)
  --format <fmt>        Output format: csv, xlsx, all (default: xlsx)
  --provider <name>     LLM provider: openai, anthropic (default: openai)
  --model <name>        LLM model (default: gpt-4o)
  --verbose             Show detailed output

Examples:
  # Analyze crawled pages
  eeat-score-helper.sh analyze ~/Downloads/example.com/_latest/crawl-data.json

  # Score single URL
  eeat-score-helper.sh score https://example.com/blog/article

  # Batch analyze
  eeat-score-helper.sh batch urls.txt --format xlsx

  # Check status
  eeat-score-helper.sh status

Output Structure:
  ~/Downloads/{domain}/{timestamp}/
    - {domain}-eeat-score-{date}.xlsx   E-E-A-T scores with reasoning
    - {domain}-eeat-score-{date}.csv    Same data in CSV format
    - eeat-summary.json                 Summary statistics

  ~/Downloads/{domain}/_latest -> symlink to latest analysis

Scoring Criteria (1-10 scale):
  - Authorship & Expertise (15%): Author credentials, verifiable entity
  - Citation Quality (15%): Source quality, substantiation
  - Content Effort (15%): Replicability, depth, original research
  - Original Content (15%): Unique perspective, new information
  - Page Intent (15%): Helpful-first vs search-first
  - Subjective Quality (15%): Engagement, clarity, credibility
  - Writing Quality (10%): Lexical diversity, readability

Grades:
  A (8.0-10.0): Excellent E-E-A-T
  B (6.5-7.9):  Good E-E-A-T
  C (5.0-6.4):  Average E-E-A-T
  D (3.5-4.9):  Poor E-E-A-T
  F (1.0-3.4):  Very poor E-E-A-T

Environment Variables:
  OPENAI_API_KEY      Required for OpenAI provider
  ANTHROPIC_API_KEY   Required for Anthropic provider

Related:
  - Site crawler: site-crawler-helper.sh
  - Crawl4AI: crawl4ai-helper.sh
EOF
    return 0
}

# Main function
main() {
    load_config
    
    local command="${1:-help}"
    shift || true
    
    case "$command" in
        analyze)
            check_dependencies || exit 1
            check_api_key || exit 1
            do_analyze "$@"
            ;;
        score)
            check_dependencies || exit 1
            check_api_key || exit 1
            do_score "$@"
            ;;
        batch)
            check_dependencies || exit 1
            check_api_key || exit 1
            do_batch "$@"
            ;;
        report)
            do_report "$@"
            ;;
        status)
            check_status
            ;;
        help|-h|--help|"")
            show_help
            ;;
        *)
            print_error "Unknown command: $command"
            show_help
            exit 1
            ;;
    esac
    
    return 0
}

main "$@"
