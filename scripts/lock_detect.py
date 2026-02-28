#!/usr/bin/env python3
"""
lock_detect.py — Lock detection for Nightcrawler plan/impl loops.

Implements two lock conditions (whichever triggers first):
1. Hard cap: 3 iterations in the same phase
2. Theme repetition: Jaccard keyword overlap > 0.5 across last 3 rejections

Usage:
    lock_detect.py check --feedbacks '<json array of feedback strings>'
    lock_detect.py jaccard --a '<text>' --b '<text>'
"""

import argparse
import json
import re
import sys

# Common English stopwords to filter out
STOPWORDS = {
    "a", "an", "the", "is", "are", "was", "were", "be", "been", "being",
    "have", "has", "had", "do", "does", "did", "will", "would", "could",
    "should", "may", "might", "must", "shall", "can", "need", "dare",
    "to", "of", "in", "for", "on", "with", "at", "by", "from", "as",
    "into", "through", "during", "before", "after", "above", "below",
    "between", "out", "off", "over", "under", "again", "further", "then",
    "once", "here", "there", "when", "where", "why", "how", "all", "both",
    "each", "few", "more", "most", "other", "some", "such", "no", "nor",
    "not", "only", "own", "same", "so", "than", "too", "very", "just",
    "because", "but", "and", "or", "if", "while", "that", "this",
    "these", "those", "it", "its", "i", "you", "he", "she", "we", "they",
    "me", "him", "her", "us", "them", "my", "your", "his", "our", "their",
    "what", "which", "who", "whom", "also", "about",
}

LOCK_THRESHOLD = 3
JACCARD_THRESHOLD = 0.5


def extract_keywords(text: str) -> set:
    """Extract keywords: lowercase, remove stopwords, split on whitespace/punctuation."""
    text = text.lower()
    # Split on non-alphanumeric characters
    words = re.split(r'[^a-z0-9]+', text)
    # Remove stopwords and short words
    return {w for w in words if w and len(w) > 2 and w not in STOPWORDS}


def jaccard_similarity(set_a: set, set_b: set) -> float:
    """Compute Jaccard similarity between two sets."""
    if not set_a and not set_b:
        return 1.0
    if not set_a or not set_b:
        return 0.0
    intersection = set_a & set_b
    union = set_a | set_b
    return len(intersection) / len(union)


def avg_jaccard(keyword_sets: list) -> float:
    """Average pairwise Jaccard similarity across a list of keyword sets."""
    if len(keyword_sets) < 2:
        return 0.0

    total = 0.0
    pairs = 0
    for i in range(len(keyword_sets)):
        for j in range(i + 1, len(keyword_sets)):
            total += jaccard_similarity(keyword_sets[i], keyword_sets[j])
            pairs += 1

    return total / pairs if pairs > 0 else 0.0


def check_lock(feedbacks: list) -> dict:
    """Check if lock conditions are met.

    Args:
        feedbacks: List of rejection feedback strings (ordered by iteration)

    Returns:
        {locked: bool, reason: str, iterations: int, jaccard: float}
    """
    iterations = len(feedbacks)

    # Hard cap check
    if iterations >= LOCK_THRESHOLD:
        return {
            "locked": True,
            "reason": f"hard_cap_{LOCK_THRESHOLD}",
            "iterations": iterations,
            "jaccard": 0.0,
        }

    # Theme repetition check (need at least 3 feedbacks)
    if iterations >= 3:
        recent = feedbacks[-3:]
        keyword_sets = [extract_keywords(fb) for fb in recent]
        overlap = avg_jaccard(keyword_sets)

        if overlap > JACCARD_THRESHOLD:
            return {
                "locked": True,
                "reason": f"jaccard_{overlap:.3f}",
                "iterations": iterations,
                "jaccard": overlap,
            }
        else:
            return {
                "locked": False,
                "reason": "below_threshold",
                "iterations": iterations,
                "jaccard": overlap,
            }

    return {
        "locked": False,
        "reason": "under_cap",
        "iterations": iterations,
        "jaccard": 0.0,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Lock detection")
    parser.add_argument("command", choices=["check", "jaccard"])
    parser.add_argument("--feedbacks", help="JSON array of feedback strings")
    parser.add_argument("--a", help="Text A for jaccard comparison")
    parser.add_argument("--b", help="Text B for jaccard comparison")

    args = parser.parse_args()

    if args.command == "check":
        feedbacks = json.loads(args.feedbacks)
        result = check_lock(feedbacks)
        print(json.dumps(result))

    elif args.command == "jaccard":
        kw_a = extract_keywords(args.a)
        kw_b = extract_keywords(args.b)
        sim = jaccard_similarity(kw_a, kw_b)
        print(json.dumps({
            "jaccard": sim,
            "keywords_a": sorted(kw_a),
            "keywords_b": sorted(kw_b),
            "overlap": sorted(kw_a & kw_b),
        }))
