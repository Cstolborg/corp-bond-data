"""
    rating_conversions.jl

Rating conversion dictionaries for converting between numerical and alphabetical ratings
across different rating agencies (S&P, Moody's, ICE).
"""

# Original 3-group conversion
rating_conversion = Dict(
    1. => "IG+",
    2. => "IG+",
    3. => "IG+",
    4. => "IG+",
    5. => "IG+",
    6. => "IG+",
    7. => "IG+",
    8. => "IG-",
    9. => "IG-",
    10. => "IG-",
    11. => "SG",
    12. => "SG",
    13. => "SG",
    14. => "SG",
    15. => "SG",
    16. => "SG",
    17. => "SG",
    18. => "SG",
    19. => "SG",
    20. => "SG",
    21. => "SG",
    22. => "SG",
    missing => missing
)

# 5-group conversion: AAA/AA, A, BBB, BB/B, Caa/Ca/C
rating_conversion5 = Dict(
  1. => "AAA/AA",   # AAA
  2. => "AAA/AA",   # AA+
  3. => "AAA/AA",   # AA
  4. => "AAA/AA",   # AA-
  5. => "A",        # A+
  6. => "A",        # A
  7. => "A",        # A-
  8. => "BBB",      # BBB+
  9. => "BBB",      # BBB
  10. => "BBB",     # BBB-
  11. => "BB/B",    # BB+
  12. => "BB/B",    # BB
  13. => "BB/B",    # BB-
  14. => "BB/B",    # B+
  15. => "BB/B",    # B
  16. => "BB/B",    # B-
  17. => "Caa/Ca/C",# CCC+
  18. => "Caa/Ca/C",# CCC
  19. => "Caa/Ca/C",# CCC-
  20. => "Caa/Ca/C",# CC
  21. => "Caa/Ca/C",# C
  22. => "Caa/Ca/C",# D (often grouped with C)
  missing => missing
)

snp_numerical_to_alphabet = Dict(
    1. => "AAA",
    2. => "AA+",
    3. => "AA",
    4. => "AA-",
    5. => "A+",
    6. => "A",
    7. => "A-",
    8. => "BBB+",
    9. => "BBB",
    10. => "BBB-",
    11. => "BB+",
    12. => "BB",
    13. => "BB-",
    14. => "B+",
    15. => "B",
    16. => "B-",
    17. => "CCC+",
    18. => "CCC",
    19. => "CCC-",
    20. => "CC",
    21. => "C",
    22. => "D",
    23. => "NR",
    24. => missing,
    25. => "AA/A-1+",
    26. => "AA-/A-1+"
)

snp_alphabet_to_numerical = Dict(
    "AAA" => 1.0,
    "AA+" => 2.0,
     "AA" => 3.0,
    "AA-" => 4.0,
     "A+" => 5.0,
      "A" => 6.0,
     "A-" => 7.0,
   "BBB+" => 8.0,
    "BBB" => 9.0,
   "BBB-" => 10.0,
    "BB+" => 11.0,
     "BB" => 12.0,
    "BB-" => 13.0,
     "B+" => 14.0,
      "B" => 15.0,
     "B-" => 16.0,
   "CCC+" => 17.0,
    "CCC" => 18.0,
   "CCC-" => 19.0,
     "CC" => 20.0,
      "C" => 21.0,
      "D" => 22.0,
     "NR" => 27.0,
  missing => 27.0,
"AA/A-1+" => 27.0,
"AA-/A-1+" => 27.
)

moody_numerical_to_alphabet = Dict(
    1. => "Aaa",
    2. => "Aa1",
    3. => "Aa2",
    4. => "Aa3",
    5. => "A1",
    6. => "A2",
    7. => "A3",
    8. => "Baa1",
    9. => "Baa2",
    10. => "Baa3",
    11. => "Ba1",
    12. => "Ba2",
    13. => "Ba3",
    14. => "B1",
    15. => "B2",
    16. => "B3",
    17. => "Caa1",
    18. => "Caa2",
    19. => "Caa3",
    20. => "Ca",
    22. => "C",
    24. => "NR"
)

moody_alphabet_to_numerical = Dict(
    "Aaa" => 1.0,
    "Aa1" => 2.0,
    "Aa2" => 3.0,
     "Aa" => 3.0,
    "Aa3" => 4.0,
     "A1" => 5.0,
     "A2" => 6.0,
      "A" => 6.0,
     "A3" => 7.0,
   "Baa1" => 8.0,
   "Baa2" => 9.0,
    "Baa" => 9.0,
   "Baa3" => 10.0,
    "Ba1" => 11.0,
    "Ba2" => 12.0,
     "Ba" => 12.0,
    "Ba3" => 13.0,
     "B1" => 14.0,
     "B2" => 15.0,
      "B" => 15.0,
     "B3" => 16.0,
   "Caa1" => 17.0,
   "Caa2" => 18.0,
    "Caa" => 18.0,
   "Caa3" => 19.0,
     "Ca" => 20.0,
      "C" => 22.0,
     "NR" => 27.0,
    "NR1" => 27.0,
    "SUSP" => 27.0,
  missing => 27.0,
)

ice_numerical_to_alphabet = Dict(
    1. => "AAA",
    2. => "AA1",
    3. => "AA2",
    4. => "AA3",
    5. => "A1",
    6. => "A2",
    7. => "A3",
    8. => "BBB1",
    9. => "BBB2",
    10. => "BBB3",
    11. => "BB1",
    12. => "BB2",
    13. => "BB3",
    14. => "B1",
    15. => "B2",
    16. => "B3",
    17. => "CCC1",
    18. => "CCC2",
    19. => "CCC3",
    20. => "CC",
    21. => "C",
    22. => "D",
    23. => "NR",
    24. => "NR"
)

ice_alphabet_to_numerical = Dict(
  "AAA" => 1.0,
  "AA1" => 2.0,
  "AA2" => 3.0,
  "AA3" => 4.0,
   "A1" => 5.0,
   "A2" => 6.0,
   "A3" => 7.0,
 "BBB1" => 8.0,
 "BBB2" => 9.0,
 "BBB3" => 10.0,
  "BB1" => 11.0,
  "BB2" => 12.0,
  "BB3" => 13.0,
   "B1" => 14.0,
   "B2" => 15.0,
   "B3" => 16.0,
 "CCC1" => 17.0,
 "CCC2" => 18.0,
 "CCC3" => 19.0,
   "CC" => 20.0,
    "C" => 21.0,
    "D" => 22.0,
   "NR" => 24.0,
   missing => 24.0
)
