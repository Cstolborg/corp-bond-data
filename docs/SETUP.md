# Setup Guide

Complete installation and configuration guide for the Corporate Bond Data Pipeline.

## Table of Contents

1. [System Requirements](#system-requirements)
2. [Software Installation](#software-installation)
3. [Project Setup](#project-setup)
4. [Data Setup](#data-setup)
5. [Configuration](#configuration)
6. [Testing Installation](#testing-installation)
7. [Running the Pipeline](#running-the-pipeline)
8. [Troubleshooting](#troubleshooting)

---

## System Requirements

### Minimum Requirements

- **CPU**: 4 cores
- **RAM**: 8 GB
- **Storage**: 10 GB free space
- **OS**: Windows 10/11, macOS 10.15+, or Linux

### Recommended Requirements

- **CPU**: 8+ cores (for parallel processing)
- **RAM**: 16 GB
- **Storage**: 20 GB free space (SSD preferred)

### Expected Runtime

- Full pipeline: 5-9 hours (depends on CPU cores)
- Main bottleneck: Bond yield calculations (4-8 hours)

---

## Software Installation

### 1. Julia (Required)

**Version**: 1.9 or higher

**Installation**:

**Windows**:
```bash
# Download from https://julialang.org/downloads/
# Run installer and add to PATH
```

**macOS**:
```bash
brew install julia
```

**Linux**:
```bash
wget https://julialang-s3.julialang.org/bin/linux/x64/1.9/julia-1.9.4-linux-x86_64.tar.gz
tar xvf julia-1.9.4-linux-x86_64.tar.gz
sudo mv julia-1.9.4 /opt/
sudo ln -s /opt/julia-1.9.4/bin/julia /usr/local/bin/julia
```

**Verify installation**:
```bash
julia --version
# Should output: julia version 1.9.x or higher
```

---

### 2. R (Required)

**Version**: 4.0 or higher

**Installation**:

**Windows**: Download from https://cran.r-project.org/bin/windows/base/

**macOS**:
```bash
brew install r
```

**Linux**:
```bash
sudo apt-get update
sudo apt-get install r-base r-base-dev
```

**Verify installation**:
```bash
R --version
# Should output: R version 4.x.x or higher
```

---

### 3. R Packages (Required)

Install required R packages for bond valuation:

```bash
R
```

Then in R console:
```r
install.packages("BondValuation")
install.packages("R.utils")

# Verify installation
library(BondValuation)
library(R.utils)
```

If you encounter issues, you may need to install dependencies:
```r
install.packages(c("timeDate", "fOptions", "fBasics"))
```

---

### 4. Python (Optional, for WRDS data download)

**Version**: 3.8 or higher

**Installation**:

**Windows**: Download from https://www.python.org/downloads/

**macOS**:
```bash
brew install python3
```

**Linux**:
```bash
sudo apt-get install python3 python3-pip
```

**Install required packages**:
```bash
pip install pandas numpy wrds
```

---

## Project Setup

### 1. Clone or Download Project

```bash
cd "C:\Users\[username]\CBS Dropbox\[your name]\"
# Or navigate to your preferred location

# If using git:
git clone [repository-url] corp-bond-data
cd corp-bond-data

# If downloading as zip:
# Extract to desired location and navigate there
```

---

### 2. Install Julia Dependencies

```bash
cd corp-bond-data

# Start Julia in project mode
julia --project=.

# In Julia REPL:
using Pkg
Pkg.instantiate()
```

This will install all required Julia packages from `Project.toml`:
- DataFrames, DataFramesMeta
- CSV, Parquet
- RCall (R integration)
- SASLib (SAS file reading)
- GLM, StatsBase, Statistics
- And others...

**Expected time**: 5-15 minutes

---

### 3. Configure RCall

RCall connects Julia to R. After installing packages, test the connection:

```julia
using RCall

# Test R connection
R"""
library(BondValuation)
library(R.utils)
print("R integration working!")
"""
```

If you encounter issues:
```julia
# Set R_HOME environment variable
ENV["R_HOME"] = "C:/Program Files/R/R-4.x.x"  # Windows
ENV["R_HOME"] = "/usr/lib/R"  # Linux
ENV["R_HOME"] = "/Library/Frameworks/R.framework/Resources"  # macOS

# Rebuild RCall
using Pkg
Pkg.build("RCall")
```

---

## Data Setup

### 1. Create Data Directory Structure

The data directories should already exist from project creation. Verify:

```bash
ls data/
# Should show: trace/  wrds/  ice_new/  output/
```

If missing, create them:
```bash
mkdir -p data/trace data/wrds data/ice_new data/output
```

---

### 2. Download Required Data

See `DATA_REQUIREMENTS.md` for detailed instructions.

**Quick checklist**:
- [ ] TRACE intraday data → `data/trace/trace_prices.sas7bdat`
- [ ] Bond-equity link → `data/wrds/bondcrsp_link.sas7bdat`
- [ ] Fama-French factors → `data/wrds/ff_daily.csv`
- [ ] GSW treasury curve → `data/output/gsw.csv`
- [ ] Bond-equity link table → `data/BondEqLink.csv`

---

### 3. WRDS Setup (for data downloads)

If using Python script for WRDS downloads:

**Set up WRDS credentials**:
```bash
# Create .pgpass file (Linux/macOS)
echo "wrds-pgdata.wharton.upenn.edu:9737:wrds:your_username:your_password" >> ~/.pgpass
chmod 600 ~/.pgpass

# Or set environment variables (all platforms)
export WRDS_USERNAME="your_username"
export WRDS_PASSWORD="your_password"
```

**Windows**: Use environment variables through System Properties

**Test connection**:
```python
python
>>> import wrds
>>> db = wrds.Connection()
>>> db.close()
```

---

## Configuration

### 1. Edit Configuration File

Open `config/data_paths.jl` and verify/modify paths:

```julia
# Check if paths match your data location
const TRACE_INTRADAY_FILE = joinpath(TRACE_DIR, "trace_prices.sas7bdat")
const BONDCRSP_LINK = joinpath(WRDS_DIR, "bondcrsp_link.sas7bdat")
# ... etc
```

### 2. Adjust Pipeline Parameters

In `config/data_paths.jl`, you can modify:

```julia
# Date filters
const TRACE_END_DATE = Date(2024, 4, 30)  # Adjust to your data

# Parallel processing
const N_WORKERS = 8  # Adjust based on your CPU cores

# Rolling windows
const ROLLING_WINDOW_MONTHS = 36  # Default: 3 years
```

---

## Testing Installation

### 1. Test Julia Environment

```bash
julia --project=.
```

```julia
# Test package loading
using DataFrames, CSV, RCall, SASLib, Parquet
println("All packages loaded successfully!")

# Test R integration
R"""
library(BondValuation)
print("BondValuation loaded!")
"""
```

### 2. Test Data Access

```julia
include("config/data_paths.jl")

# Check if files exist
@assert isfile(TRACE_INTRADAY_FILE) "TRACE file not found at: $TRACE_INTRADAY_FILE"
@assert isfile(BONDCRSP_LINK) "Bond link file not found at: $BONDCRSP_LINK"
@assert isfile(GSW_FILE) "GSW file not found at: $GSW_FILE"

println("All required data files found!")
```

### 3. Test SAS File Reading

```julia
using SASLib

# Try reading a small portion of TRACE
trace_test = SASLib.readsas(TRACE_INTRADAY_FILE, 1000)  # Read first 1000 rows
println("Successfully read TRACE file: $(nrow(trace_test)) rows")
```

---

## Running the Pipeline

### 1. Start Julia with Multiple Workers (for parallel processing)

```bash
julia --project=. -p 8  # Start with 8 workers
```

Or from within Julia:
```julia
using Distributed
addprocs(8)  # Add 8 worker processes

@everywhere using DataFrames, DataFramesMeta, RCall
@everywhere include("src/preprocessing.jl")
```

### 2. Run Main Pipeline

**Option A**: Run from command line
```bash
julia --project=. scripts/create_datasets.jl
```

**Option B**: Run from Julia REPL
```julia
include("scripts/create_datasets.jl")
```

**Expected output**:
```
[ Info: Data Pipeline Configuration Loaded
[ Info: Loading TRACE intraday data...
[ Info: Processing 1,234,567 trades...
[ Info: Computing risk measures (parallel)...
[ Info: Progress: ████████████████████ 100%
[ Info: Pipeline complete! Output saved to: data/output/bonds_full.csv
```

### 3. Monitor Progress

The pipeline will print progress updates. Key stages:
1. Load TRACE intraday → ~5-10 min
2. Aggregate to daily → ~5 min
3. **Compute risk measures → 2-4 hours** (slowest)
4. Create bond returns → ~10-20 min
5. **Treasury risk measures → 2-4 hours** (second slowest)
6. Factor construction → ~20-30 min

**Total**: 5-9 hours

### 4. Check Outputs

After completion, verify outputs:
```julia
using CSV, DataFrames

# Load main output
bonds = CSV.read("data/output/bonds_full.csv", DataFrame)
println("Bonds dataset: $(nrow(bonds)) rows, $(ncol(bonds)) columns")

# Check key variables
names(bonds)
```

---

## Troubleshooting

### Issue: RCall not finding R

**Error**: `R_HOME not found`

**Solution**:
```julia
# Find R installation
# Windows: Usually "C:/Program Files/R/R-4.x.x"
# macOS: Usually "/Library/Frameworks/R.framework/Resources"
# Linux: Usually "/usr/lib/R"

ENV["R_HOME"] = "[your R path]"
using Pkg
Pkg.build("RCall")
```

---

### Issue: SASLib cannot read files

**Error**: `Error reading SAS file`

**Solutions**:
1. Verify file is valid SAS7BDAT format
2. Try re-exporting from WRDS
3. Convert to CSV as alternative:
   ```r
   # In R
   library(haven)
   data <- read_sas("trace_prices.sas7bdat")
   write.csv(data, "trace_prices.csv", row.names=FALSE)
   ```

---

### Issue: Out of memory

**Error**: `OutOfMemoryError`

**Solutions**:
1. Increase swap space
2. Process data in chunks (modify scripts)
3. Use machine with more RAM
4. Close other applications

---

### Issue: Parallel processing not working

**Error**: `No workers available`

**Solutions**:
```julia
using Distributed
addprocs(8)  # Add workers manually

# Verify workers
workers()  # Should show [2, 3, 4, 5, 6, 7, 8, 9]

# Load packages on all workers
@everywhere using DataFrames, RCall
```

---

### Issue: Bond valuation taking too long

**Expected**: 2-4 hours per valuation stage

**If much longer**:
1. Verify R packages installed correctly
2. Check CPU isn't throttled
3. Reduce `N_WORKERS` if too many workers cause contention
4. Consider running overnight

---

### Issue: Missing data errors

**Error**: `File not found` or `KeyError: column not found`

**Solutions**:
1. Verify all required data downloaded (see DATA_REQUIREMENTS.md)
2. Check file paths in `config/data_paths.jl`
3. Ensure data files have correct column names
4. Check for date range mismatches

---

## Performance Optimization

### Use SSD

If possible, place data on SSD for faster I/O:
```julia
# In config/data_paths.jl, change DATA_DIR to SSD location
const DATA_DIR = "D:/fast_storage/bond_data"  # Example
```

### Adjust Worker Count

Optimal worker count = number of physical cores:
```julia
# Check CPU cores
using Hwloc
num_physical_cores()

# Use that many workers
const N_WORKERS = 8  # Adjust in config
```

### Process Subsets First

For testing, process a smaller date range:
```julia
# In create_datasets.jl, modify filter
@subset!(trace_intraday, :date .< Date(2024, 1, 31))  # Just Jan 2024
```

---

## Next Steps

After successful installation and test:

1. **Run full pipeline**: `julia --project=. scripts/create_datasets.jl`
2. **Verify outputs**: Check `data/output/` for all files
3. **Run comparison tests**: `julia --project=. tests/compare_outputs.jl`
4. **Create shareable data**: `julia --project=. scripts/data_to_share.jl`

---

## Getting Help

- **Installation issues**: Check Julia Discourse (discourse.julialang.org)
- **R integration**: RCall.jl documentation
- **Data issues**: See DATA_REQUIREMENTS.md
- **Pipeline questions**: [Your contact/repository issues]

---

## Appendix: Full Installation Script

For automated setup (Linux/macOS):

```bash
#!/bin/bash

# Install Julia dependencies
julia --project=. -e 'using Pkg; Pkg.instantiate()'

# Install R packages
R -e 'install.packages(c("BondValuation", "R.utils"), repos="https://cran.r-project.org")'

# Install Python packages (if using WRDS)
pip install pandas numpy wrds

# Test installation
julia --project=. -e 'using DataFrames, RCall; println("Installation successful!")'
```

Save as `install.sh`, make executable: `chmod +x install.sh`, run: `./install.sh`
