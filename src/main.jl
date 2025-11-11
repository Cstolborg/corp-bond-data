"""
    main.jl

Main entry point for the corporate bond data processing pipeline.
Loads all modules and utilities in the correct order.
"""

using CSV, Parquet, DataFramesMeta
using Statistics, StatsBase
using Dates
using ShiftedArrays: lag, lead

# Load configuration
include("../config/data_paths.jl")

# ============================================================================
# DataLoader Module
# ============================================================================

module DataLoader

using DataFramesMeta, Dates, CSV, Parquet, SASLib, XLSX
using ShiftedArrays: lag
using GLM
using StatsPlots
using TexTables

# Load rating conversions (used by data loader)
include("rating_conversions.jl")

# Load data loading functions
include("data_loader.jl")

end  # end DataLoader module

# ============================================================================
# Preprocess Module
# ============================================================================

module Preprocess

using CSV, Parquet, SASLib
using DataFramesMeta
using Statistics, StatsBase
using Dates
using ShiftedArrays: lag, lead
using Roots
import Downloads
using RCall

# Import DataLoader module
using ..DataLoader: DataLoader, load_rf, load_mergent, load_trade_dates, load_cusip_permno_gvkey

# Load utility functions needed by preprocessing
include("utils.jl")
include("rating_conversions.jl")

# Load preprocessing functions
include("preprocessing.jl")
include("compute_bond_returns.jl")


end  # end Preprocess module

# ============================================================================
# Factors Module
# ============================================================================

module Factors

using DataFramesMeta, Dates
using GLM
using Statistics
using StatsBase
using RCall

# Import DataLoader module
using ..DataLoader: DataLoader, load_rf, load_BofA_market, load_long_term_gov, load_vix, load_ff

# Load utility functions needed by factors
include("utils.jl")

# Load factor functions
include("factors.jl")

end  # end Factors module

# ============================================================================
# Pfs (Portfolios) Module
# ============================================================================

module Pfs

using DataFramesMeta, Dates, CSV, Parquet
using GLM
using Statistics
using StatsPlots
using CategoricalArrays
using CovarianceMatrices
using StatsBase
using LaTeXStrings
using ProgressMeter
using XLSX
using Distributions
using RCall
import MultipleTesting

# Import other modules
using ..DataLoader: DataLoader
using ..Factors: Factors

# Load utility functions needed by portfolios
include("utils.jl")

# Load portfolio functions
include("portfolios.jl")

end  # end Pfs module

# ============================================================================
# Top-level utility functions
# ============================================================================

# Load utility functions at top level for convenience
include("utils.jl")
include("rating_conversions.jl")

@info """
Corporate Bond Data Pipeline Loaded
====================================
Modules available:
- DataLoader: Data loading functions
- Preprocess: Data preprocessing and bond valuation
- Factors: Factor computation
- Pfs: Portfolio construction and analysis

Configuration: See config/data_paths.jl
"""
