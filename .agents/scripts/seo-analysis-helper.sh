#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2129,SC2155

# SEO Analysis Helper Script
# Analyzes exported SEO data for ranking opportunities and content cannibalization
#
# Usage: seo-analysis-helper.sh <domain> [command] [options]
#
# Author: AI DevOps Framework
# Version: 1.0.0

set -euo pipefail

# Source shared constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
if [[ -f "$SCRIPT_DIR/shared-constants.sh" ]]; then
    source "$SCRIPT_DIR/shared-constants.sh"
fi

# =============================================================================
# Configuration
# =============================================================================

readonly SEO_DATA_DIR="$HOME/.aidevops/.agent-workspace/work/seo-data"

# Analysis thresholds
readonly QUICK_WIN_MIN_POSITION=4
readonly QUICK_WIN_MAX_POSITION=20
readonly QUICK_WIN_MIN_IMPRESSIONS=100

readonly STRIKING_DISTANCE_MIN_POSITION=11
readonly STRIKING_DISTANCE_MAX_POSITION=30
readonly STRIKING_DISTANCE_MIN_VOLUME=500

readonly LOW_CTR_THRESHOLD=0.02  # 2% CTR considered low
readonly LOW_CTR_MIN_IMPRESSIONS=500

# Scoring constants
readonly SCORE_IMPRESSION_DIVISOR=100       # Normalize impressions in score calculation
readonly SCORE_POSITION_WEIGHT=5            # Weight for position proximity to page 1
readonly SCORE_POSITION_OFFSET=21           # Offset for position scoring (21 - position)
readonly SCORE_STRIKING_OFFSET=31           # Offset for striking distance scoring
readonly VOLUME_ESTIMATION_DIVISOR=10       # Estimate volume from impressions when unavailable
readonly TARGET_CTR_IMPROVEMENT=0.05        # Target CTR (5%) for potential clicks calculation

# =============================================================================
# Utility Functions
# =============================================================================

print_header() { local msg="$1"; echo -e "${PURPLE}=== $msg ===${NC}"; return 0; }
# =============================================================================
# TOON Parsing Functions
# =============================================================================

# Parse TOON file and extract data rows (skip header and separator)
parse_toon_data() {
    local file="$1"
    
    # Skip lines until we hit ---, then output the rest (skipping header row)
    awk 'BEGIN{data=0; header=0} /^---$/{data=1; next} data==1 && header==0{header=1; next} data==1{print}' "$file"
    return 0
}

# Get metadata from TOON header
get_toon_meta() {
    local file="$1"
    local key="$2"
    
    awk -F'\t' -v key="$key" '$1==key{print $2; exit}' "$file"
    return 0
}

# Find latest TOON file for a source
find_latest_toon() {
    local domain_dir="$1"
    local source="$2"
    
    # Find most recent file matching pattern (use find to avoid set -e issues)
    find "$domain_dir" -maxdepth 1 -name "${source}-*.toon" -print 2>/dev/null | sort -r | head -1
    return 0
}

# =============================================================================
# Analysis Functions
# =============================================================================

# Quick Wins: High impressions, positions 4-20
analyze_quick_wins() {
    local domain="$1"
    local domain_dir="$SEO_DATA_DIR/$domain"
    local output_file="$2"
    
    print_header "Quick Wins Analysis"
    print_info "Criteria: Position $QUICK_WIN_MIN_POSITION-$QUICK_WIN_MAX_POSITION, Impressions > $QUICK_WIN_MIN_IMPRESSIONS"
    echo ""
    
    # Collect data from all sources
    local temp_file
    temp_file=$(mktemp)
    trap 'rm -f "$temp_file"' RETURN
    
    for toon_file in "$domain_dir"/*.toon; do
        [[ -f "$toon_file" ]] || continue
        [[ "$(basename "$toon_file")" == analysis-* ]] && continue
        
        local source
        source=$(get_toon_meta "$toon_file" "source")
        
        # Parse and filter: position between 4-20, impressions > 100
        parse_toon_data "$toon_file" | awk -F'\t' -v src="$source" \
            -v min_pos="$QUICK_WIN_MIN_POSITION" \
            -v max_pos="$QUICK_WIN_MAX_POSITION" \
            -v min_imp="$QUICK_WIN_MIN_IMPRESSIONS" \
            -v imp_div="$SCORE_IMPRESSION_DIVISOR" \
            -v pos_weight="$SCORE_POSITION_WEIGHT" \
            -v pos_offset="$SCORE_POSITION_OFFSET" \
            'NF>=6 && $6>=min_pos && $6<=max_pos && $4>=min_imp {
                # Calculate opportunity score: higher impressions + closer to page 1 = better
                score = ($4 / imp_div) + ((pos_offset - $6) * pos_weight)
                print $1 "\t" $2 "\t" $4 "\t" $6 "\t" score "\t" src
            }' >> "$temp_file"
    done
    
    # Sort by opportunity score and output
    if [[ -s "$temp_file" ]]; then
        echo "query	page	impressions	position	score	source" >> "$output_file"
        sort -t$'\t' -k5 -rn "$temp_file" | head -50 >> "$output_file"
        
        local count
        count=$(wc -l < "$temp_file" | tr -d ' ')
        print_success "Found $count quick win opportunities"
        
        # Show top 10
        echo ""
        echo "Top 10 Quick Wins:"
        echo "Query | Position | Impressions | Source"
        echo "------|----------|-------------|-------"
        sort -t$'\t' -k5 -rn "$temp_file" | head -10 | while IFS=$'\t' read -r query page imp pos score src; do
            printf "%.40s | %.1f | %d | %s\n" "$query" "$pos" "$imp" "$src"
        done
    else
        print_warning "No quick wins found"
    fi
    
    rm -f "$temp_file"
    echo ""
    return 0
}

# Striking Distance: Positions 11-30 with high volume
analyze_striking_distance() {
    local domain="$1"
    local domain_dir="$SEO_DATA_DIR/$domain"
    local output_file="$2"
    
    print_header "Striking Distance Analysis"
    print_info "Criteria: Position $STRIKING_DISTANCE_MIN_POSITION-$STRIKING_DISTANCE_MAX_POSITION, Volume > $STRIKING_DISTANCE_MIN_VOLUME"
    echo ""
    
    local temp_file
    temp_file=$(mktemp)
    trap 'rm -f "$temp_file"' RETURN
    
    for toon_file in "$domain_dir"/*.toon; do
        [[ -f "$toon_file" ]] || continue
        [[ "$(basename "$toon_file")" == analysis-* ]] && continue
        
        local source
        source=$(get_toon_meta "$toon_file" "source")
        
        # For sources with volume data (ahrefs, dataforseo), use column 7
        # For GSC/Bing, estimate from impressions
        parse_toon_data "$toon_file" | awk -F'\t' -v src="$source" \
            -v min_pos="$STRIKING_DISTANCE_MIN_POSITION" \
            -v max_pos="$STRIKING_DISTANCE_MAX_POSITION" \
            -v min_vol="$STRIKING_DISTANCE_MIN_VOLUME" \
            -v vol_div="$VOLUME_ESTIMATION_DIVISOR" \
            -v strike_offset="$SCORE_STRIKING_OFFSET" \
            'NF>=6 && $6>=min_pos && $6<=max_pos {
                volume = (NF>=7 && $7>0) ? $7 : ($4 / vol_div)
                if (volume >= min_vol) {
                    # Score: volume * position proximity to page 1
                    score = volume * (strike_offset - $6)
                    print $1 "\t" $2 "\t" volume "\t" $6 "\t" score "\t" src
                }
            }' >> "$temp_file"
    done
    
    if [[ -s "$temp_file" ]]; then
        echo "" >> "$output_file"
        echo "# Striking Distance" >> "$output_file"
        echo "query	page	volume	position	score	source" >> "$output_file"
        sort -t$'\t' -k5 -rn "$temp_file" | head -50 >> "$output_file"
        
        local count
        count=$(wc -l < "$temp_file" | tr -d ' ')
        print_success "Found $count striking distance opportunities"
        
        echo ""
        echo "Top 10 Striking Distance:"
        echo "Query | Position | Volume | Source"
        echo "------|----------|--------|-------"
        sort -t$'\t' -k5 -rn "$temp_file" | head -10 | while IFS=$'\t' read -r query page vol pos score src; do
            printf "%.40s | %.1f | %d | %s\n" "$query" "$pos" "$vol" "$src"
        done
    else
        print_warning "No striking distance opportunities found"
    fi
    
    rm -f "$temp_file"
    echo ""
    return 0
}

# Low CTR: High impressions but low click-through rate
analyze_low_ctr() {
    local domain="$1"
    local domain_dir="$SEO_DATA_DIR/$domain"
    local output_file="$2"
    
    print_header "Low CTR Analysis"
    print_info "Criteria: CTR < ${LOW_CTR_THRESHOLD}, Impressions > $LOW_CTR_MIN_IMPRESSIONS"
    echo ""
    
    local temp_file
    temp_file=$(mktemp)
    trap 'rm -f "$temp_file"' RETURN
    
    for toon_file in "$domain_dir"/*.toon; do
        [[ -f "$toon_file" ]] || continue
        [[ "$(basename "$toon_file")" == analysis-* ]] && continue
        
        local source
        source=$(get_toon_meta "$toon_file" "source")
        
        parse_toon_data "$toon_file" | awk -F'\t' -v src="$source" \
            -v max_ctr="$LOW_CTR_THRESHOLD" \
            -v min_imp="$LOW_CTR_MIN_IMPRESSIONS" \
            -v target_ctr="$TARGET_CTR_IMPROVEMENT" \
            'NF>=6 && $5<max_ctr && $4>=min_imp && $6<=10 {
                # Potential clicks if CTR improved to target
                potential = $4 * target_ctr
                print $1 "\t" $2 "\t" $4 "\t" $5 "\t" $6 "\t" potential "\t" src
            }' >> "$temp_file"
    done
    
    if [[ -s "$temp_file" ]]; then
        echo "" >> "$output_file"
        echo "# Low CTR Opportunities" >> "$output_file"
        echo "query	page	impressions	ctr	position	potential_clicks	source" >> "$output_file"
        sort -t$'\t' -k6 -rn "$temp_file" | head -50 >> "$output_file"
        
        local count
        count=$(wc -l < "$temp_file" | tr -d ' ')
        print_success "Found $count low CTR opportunities"
        
        echo ""
        echo "Top 10 Low CTR (title/meta optimization needed):"
        echo "Query | Position | CTR | Impressions"
        echo "------|----------|-----|------------"
        sort -t$'\t' -k6 -rn "$temp_file" | head -10 | while IFS=$'\t' read -r query page imp ctr pos potential src; do
            printf "%.40s | %.1f | %.2f%% | %d\n" "$query" "$pos" "$(echo "$ctr * 100" | bc -l 2>/dev/null || echo "$ctr")" "$imp"
        done
    else
        print_warning "No low CTR opportunities found"
    fi
    
    rm -f "$temp_file"
    echo ""
    return 0
}

# Content Cannibalization: Same query ranking with multiple URLs
analyze_cannibalization() {
    local domain="$1"
    local domain_dir="$SEO_DATA_DIR/$domain"
    local output_file="$2"
    
    print_header "Content Cannibalization Analysis"
    print_info "Finding queries with multiple ranking URLs"
    echo ""
    
    local temp_file
    temp_file=$(mktemp)
    local query_pages
    query_pages=$(mktemp)
    trap 'rm -f "$temp_file" "$query_pages"' RETURN
    
    # Collect all query-page pairs
    for toon_file in "$domain_dir"/*.toon; do
        [[ -f "$toon_file" ]] || continue
        [[ "$(basename "$toon_file")" == analysis-* ]] && continue
        
        local source
        source=$(get_toon_meta "$toon_file" "source")
        
        parse_toon_data "$toon_file" | awk -F'\t' -v src="$source" \
            'NF>=6 && $2!="" {
                print tolower($1) "\t" $2 "\t" $6 "\t" $4 "\t" src
            }' >> "$query_pages"
    done
    
    # Find queries with multiple pages
    if [[ -s "$query_pages" ]]; then
        # Group by query, find those with multiple unique pages
        # Use delimiter-wrapped matching to avoid substring false positives
        sort -t$'\t' -k1,1 "$query_pages" | awk -F'\t' '
        BEGIN {
            DELIM = "|"  # Delimiter for page list
        }
        {
            query = $1
            page = $2
            pos = $3
            imp = $4
            src = $5
            
            if (query != prev_query && prev_query != "") {
                if (page_count > 1) {
                    # Output cannibalization (remove leading delimiter)
                    gsub(/^\|/, "", pages)
                    gsub(/^,/, "", positions)
                    print prev_query "\t" pages "\t" positions "\t" page_count
                }
                pages = ""
                positions = ""
                page_count = 0
            }
            
            # Check if this page is already seen for this query
            # Use delimiter-wrapped matching to avoid substring false positives
            if (index(pages, DELIM page DELIM) == 0 && index(pages, DELIM page) != length(pages) - length(page)) {
                if (pages != "") {
                    pages = pages DELIM page
                    positions = positions "," pos
                } else {
                    pages = DELIM page
                    positions = pos
                }
                page_count++
            }
            
            prev_query = query
        }
        END {
            if (page_count > 1) {
                gsub(/^\|/, "", pages)
                gsub(/^,/, "", positions)
                print prev_query "\t" pages "\t" positions "\t" page_count
            }
        }' > "$temp_file"
        
        if [[ -s "$temp_file" ]]; then
            echo "" >> "$output_file"
            echo "# Content Cannibalization" >> "$output_file"
            echo "query	pages	positions	page_count" >> "$output_file"
            sort -t$'\t' -k4 -rn "$temp_file" | head -50 >> "$output_file"
            
            local count
            count=$(wc -l < "$temp_file" | tr -d ' ')
            print_success "Found $count cannibalized queries"
            
            echo ""
            echo "Top 10 Cannibalized Queries:"
            echo "Query | # Pages | Positions"
            echo "------|---------|----------"
            sort -t$'\t' -k4 -rn "$temp_file" | head -10 | while IFS=$'\t' read -r query pages positions page_count; do
                printf "%.40s | %d | %s\n" "$query" "$page_count" "$positions"
            done
        else
            print_warning "No content cannibalization detected"
        fi
    else
        print_warning "No data available for cannibalization analysis"
    fi
    
    rm -f "$temp_file" "$query_pages"
    echo ""
    return 0
}

# Full analysis
run_full_analysis() {
    local domain="$1"
    local domain_dir="$SEO_DATA_DIR/$domain"
    
    if [[ ! -d "$domain_dir" ]]; then
        print_error "No data found for domain: $domain"
        print_error "Run 'seo-export-helper.sh all $domain' first"
        return 1
    fi
    
    # Check for TOON files (use find to avoid set -e issues with ls glob)
    local toon_count
    toon_count=$(find "$domain_dir" -maxdepth 1 -name "*.toon" ! -name "analysis-*" 2>/dev/null | wc -l | tr -d ' ')
    
    if [[ "$toon_count" == "0" ]] || [[ -z "$toon_count" ]]; then
        print_error "No export files found for $domain"
        return 1
    fi
    
    print_info "Found $toon_count data files for $domain"
    echo ""
    
    # Generate output filename
    local today
    today=$(date +%Y-%m-%d)
    local output_file="$domain_dir/analysis-${today}.toon"
    
    # Create analysis header
    cat > "$output_file" << EOF
domain	$domain
type	analysis
analyzed	$(date -u +"%Y-%m-%dT%H:%M:%SZ")
sources	$toon_count
---
# Quick Wins
EOF
    
    # Run all analyses
    analyze_quick_wins "$domain" "$output_file"
    analyze_striking_distance "$domain" "$output_file"
    analyze_low_ctr "$domain" "$output_file"
    analyze_cannibalization "$domain" "$output_file"
    
    print_header "Analysis Complete"
    print_success "Full report saved to: $output_file"
    
    return 0
}

# =============================================================================
# Help
# =============================================================================

show_help() {
    cat << 'EOF'
SEO Analysis Helper

Analyze exported SEO data for ranking opportunities and content issues.

Usage:
    seo-analysis-helper.sh <domain> [command] [options]

Commands:
    analyze              Run full analysis (default)
    quick-wins           Find quick win opportunities (pos 4-20)
    striking-distance    Find striking distance keywords (pos 11-30)
    low-ctr              Find low CTR opportunities
    cannibalization      Detect content cannibalization
    summary              Show summary of available data

Options:
    --help, -h           Show this help message

Analysis Types:

    Quick Wins
    - Position 4-20 with high impressions
    - Small improvements can move to page 1
    - Focus: on-page optimization, internal linking

    Striking Distance
    - Position 11-30 with high search volume
    - Potential for significant traffic gains
    - Focus: content expansion, backlinks

    Low CTR
    - High impressions but low click-through rate
    - Title/meta description optimization needed
    - Focus: compelling titles, rich snippets

    Cannibalization
    - Same query ranking with multiple URLs
    - Consolidate or differentiate content
    - Focus: canonical tags, content merging

Examples:
    # Run full analysis
    seo-analysis-helper.sh example.com

    # Check for cannibalization only
    seo-analysis-helper.sh example.com cannibalization

    # View data summary
    seo-analysis-helper.sh example.com summary

Output:
    ~/.aidevops/.agent-workspace/work/seo-data/{domain}/analysis-{date}.toon

EOF
    return 0
}

# Show summary of available data
show_summary() {
    local domain="$1"
    local domain_dir="$SEO_DATA_DIR/$domain"
    
    if [[ ! -d "$domain_dir" ]]; then
        print_error "No data found for domain: $domain"
        return 1
    fi
    
    print_header "Data Summary for $domain"
    echo ""
    
    for toon_file in "$domain_dir"/*.toon; do
        [[ -f "$toon_file" ]] || continue
        
        local filename
        filename=$(basename "$toon_file")
        local source
        source=$(get_toon_meta "$toon_file" "source")
        local exported
        exported=$(get_toon_meta "$toon_file" "exported")
        local row_count
        row_count=$(parse_toon_data "$toon_file" | wc -l | tr -d ' ')
        
        echo "$filename"
        echo "  Source: $source"
        echo "  Exported: $exported"
        echo "  Rows: $row_count"
        echo ""
    done
    
    return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
    local domain=""
    local command="analyze"
    local arg
    
    while [[ $# -gt 0 ]]; do
        arg="$1"
        case "$arg" in
            --help|-h)
                show_help
                return 0
                ;;
            -*)
                print_error "Unknown option: $arg"
                return 1
                ;;
            *)
                if [[ -z "$domain" ]]; then
                    domain="$arg"
                else
                    command="$arg"
                fi
                shift
                ;;
        esac
    done
    
    if [[ -z "$domain" ]]; then
        print_error "Domain is required"
        echo "Usage: seo-analysis-helper.sh <domain> [command]"
        return 1
    fi
    
    local domain_dir="$SEO_DATA_DIR/$domain"
    local output_file="$domain_dir/analysis-$(date +%Y-%m-%d).toon"
    
    case "$command" in
        analyze|full)
            run_full_analysis "$domain"
            ;;
        quick-wins)
            [[ -d "$domain_dir" ]] || { print_error "No data for $domain"; return 1; }
            echo "domain	$domain" > "$output_file"
            echo "---" >> "$output_file"
            analyze_quick_wins "$domain" "$output_file"
            ;;
        striking-distance)
            [[ -d "$domain_dir" ]] || { print_error "No data for $domain"; return 1; }
            echo "domain	$domain" > "$output_file"
            echo "---" >> "$output_file"
            analyze_striking_distance "$domain" "$output_file"
            ;;
        low-ctr)
            [[ -d "$domain_dir" ]] || { print_error "No data for $domain"; return 1; }
            echo "domain	$domain" > "$output_file"
            echo "---" >> "$output_file"
            analyze_low_ctr "$domain" "$output_file"
            ;;
        cannibalization)
            [[ -d "$domain_dir" ]] || { print_error "No data for $domain"; return 1; }
            echo "domain	$domain" > "$output_file"
            echo "---" >> "$output_file"
            analyze_cannibalization "$domain" "$output_file"
            ;;
        summary)
            show_summary "$domain"
            ;;
        *)
            print_error "Unknown command: $command"
            echo "Use 'seo-analysis-helper.sh --help' for usage"
            return 1
            ;;
    esac
    
    return 0
}

main "$@"
