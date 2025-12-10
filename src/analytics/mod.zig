//! Analytics Module for llm-cost
//!
//! Provides fairness analysis and tokenization metrics across languages.
//!
//! Main components:
//! - `FairnessAnalyzer`: Orchestrates multi-language token tax analysis
//! - `metrics`: Gini, Fertility, Parity calculations
//! - `corpus`: JSON corpus configuration loader
//! - `word_count`: Word counting strategies for different languages

pub const metrics = @import("metrics.zig");
pub const word_count = @import("word_count.zig");
pub const corpus = @import("corpus.zig");
pub const fairness = @import("fairness.zig");

// Re-export main types for convenience
pub const FairnessAnalyzer = fairness.FairnessAnalyzer;
pub const FairnessReport = fairness.FairnessReport;
pub const LanguageStats = fairness.LanguageStats;
pub const CorpusConfig = corpus.CorpusConfig;
pub const LanguageConfig = corpus.LanguageConfig;
pub const WordCountMode = word_count.WordCountMode;

// Re-export utility functions
pub const calculateGini = metrics.calculateGini;
pub const calculateFertility = metrics.calculateFertility;
pub const calculateParityRatio = metrics.calculateParityRatio;
pub const countWords = word_count.countWords;
pub const loadCorpus = corpus.loadCorpus;
pub const runFairnessAnalysis = fairness.runFairnessAnalysis;

// =============================================================================
// Tests - ensure all modules compile
// =============================================================================

test "analytics: all modules compile" {
    _ = metrics;
    _ = word_count;
    _ = corpus;
    _ = fairness;
}

test "analytics: re-exports work" {
    _ = FairnessAnalyzer;
    _ = FairnessReport;
    _ = LanguageStats;
    _ = CorpusConfig;
    _ = WordCountMode;
    _ = calculateGini;
    _ = calculateFertility;
    _ = countWords;
}
