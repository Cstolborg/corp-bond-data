# Migration Plan

This document outlines the step-by-step process for migrating the clean_data functionality from the original `corp-bond-replication` project to this standalone `corp-bond-data` project.

## Project Status

✅ **Phase 1 Complete**: Project structure created

The following has been completed:
- Directory structure
- Project.toml with dependencies
- Configuration file (config/data_paths.jl)
- Documentation (README, SETUP, DATA_REQUIREMENTS)
- Test framework
- Placeholder source files

## Next Steps

### Phase 2: Extract Core Functions (3-4 hours)

Extract functions from the original `src/` directory to the new project.

#### Step 2.1: Extract DataLoader Functions

**Source**: `corp-bond-replication/src/utils/main.jl`
**Target**: `corp-bond-data/src/data_loader.jl`

Functions to extract:
- [ ] `load_trace_intraday()`
- [ ] `load_rf()`
- [ ] `load_ff()`
- [ ] `load_trade_dates()`
- [ ] `load_cusip_permno_gvkey()`
- [ ] `load_BofA_market()`
- [ ] `load_long_term_gov()`
- [ ] `load_vix()`

**Action**:
```julia
# Read original file
original = read("corp-bond-replication/src/utils/main.jl", String)

# Extract DataLoader module or individual functions
# Copy to src/data_loader.jl
# Remove any unused dependencies
```

---

#### Step 2.2: Extract Preprocessing Functions

**Source**: `corp-bond-replication/src/preprocessing/main.jl`
**Target**: `corp-bond-data/src/preprocessing.jl`

Functions to extract:
- [ ] `Fisd()`
- [ ] `add_ratings()`
- [ ] `filter_bonds!()`
- [ ] `bond_values()` (critical - handles R integration)
- [ ] `bond_dates()`
- [ ] `compute_bond_returns()`
- [ ] `agg_daily_trace_to_month()`
- [ ] `add_treasury_returns()`
- [ ] `process_ice()`
- [ ] `process_warga()`
- [ ] `combine_warga_ice()`
- [ ] `get_coupon_schedule()`
- [ ] `price_coupon_treasury()`
- [ ] `bondval()`

**Note**: This is the largest extraction. Include all helper functions used by these main functions.

---

#### Step 2.3: Extract Factor Functions

**Source**: `corp-bond-replication/src/factors/main.jl`
**Target**: `corp-bond-data/src/factors.jl`

Functions to extract:
- [ ] `age_percent()`
- [ ] `book_to_market()`
- [ ] `liquidity_betas()`
- [ ] `VaR()`
- [ ] `vol()`
- [ ] `value()`

---

#### Step 2.4: Extract Portfolio Functions

**Source**: `corp-bond-replication/src/portfolios/main.jl`
**Target**: `corp-bond-data/src/portfolios.jl`

Functions to extract:
- [ ] `FactorRegressor()`
- [ ] `factor_pipeline()`
- [ ] `compute_rolling_signals()`
- [ ] `compute_characteristic_pfs()`
- [ ] `compute_factor_returns()`

---

#### Step 2.5: Extract Utility Functions

**Source**: `corp-bond-replication/src/utils/functions.jl`
**Target**: `corp-bond-data/src/utils.jl`

Functions to extract:
- [ ] `calendar_fill()`
- [ ] `add_permno()`
- [ ] `date_to_year_month_day!()`
- [ ] `year_month_day_to_date!()`
- [ ] `replace_nans()`

---

### Phase 3: Migrate Scripts (2-3 hours)

Copy and adapt the clean_data scripts to work with the new src/ structure.

#### Step 3.1: Copy Scripts

Copy all scripts from `corp-bond-replication/scripts/clean_data/` to `corp-bond-data/scripts/`:

- [ ] `create_datasets.jl`
- [ ] `update_datasets.jl`
- [ ] `create_datasets_oos_warga.jl`
- [ ] `preprocess_new_ice.jl`
- [ ] `data_to_share.jl`
- [ ] `utils_clean_data.jl`
- [ ] `wrds_get_bond_rets.py`

#### Step 3.2: Update Import Statements

In each script, replace:
```julia
# Old
include("../../src/main.jl")
using .DataLoader, .Preprocess, .Factors, .Pfs

# New
include("../src/data_loader.jl")
include("../src/preprocessing.jl")
include("../src/factors.jl")
include("../src/portfolios.jl")
include("../src/utils.jl")
```

#### Step 3.3: Update Path References

Replace hardcoded paths with config references:
```julia
# Old
file = "scripts/scientific_replication/data/bonds.csv"

# New
include("../config/data_paths.jl")
file = BONDS
```

#### Step 3.4: Update Data Loading

Ensure all data loading uses the config paths:
```julia
# Use constants from data_paths.jl
trace = load_trace_intraday(TRACE_INTRADAY_FILE)
fisd = Fisd(FISD_DIR)
```

---

### Phase 4: Test Migration (1-2 hours)

#### Step 4.1: Setup Test Environment

1. Copy sample data to new project:
   ```bash
   # Copy a subset of data for initial testing
   cp "corp-bond-replication/data/trace/trace_prices.sas7bdat" "corp-bond-data/data/trace/"
   # ... copy other required files
   ```

2. Ensure all data paths in `config/data_paths.jl` are correct

#### Step 4.2: Test Individual Functions

Create a test script to verify each extracted function works:

```julia
# test_functions.jl
include("src/data_loader.jl")
include("src/preprocessing.jl")

# Test data loading
trace = load_trace_intraday(TRACE_INTRADAY_FILE)
@assert nrow(trace) > 0 "TRACE data loaded"

# Test preprocessing
fisd = Fisd(FISD_DIR)
@assert nrow(fisd) > 0 "FISD data loaded"

# ... test other functions
```

#### Step 4.3: Run Small-Scale Pipeline Test

Run `create_datasets.jl` with a small date range:
```julia
# Modify in script temporarily:
@subset!(trace_intraday, Date(2024, 1, 1) .<= :date .< Date(2024, 2, 1))
```

Verify it completes without errors.

#### Step 4.4: Run Full Pipeline

Run complete pipeline:
```bash
julia --project=. -p 8 scripts/create_datasets.jl
```

Expected runtime: 5-9 hours

---

### Phase 5: Validation (1-2 hours)

#### Step 5.1: Output Comparison

1. **Prepare old outputs**:
   ```bash
   mkdir tests/old_output
   cp corp-bond-replication/scripts/scientific_replication/data/*.csv tests/old_output/
   cp corp-bond-replication/scripts/scientific_replication/data/*.pq tests/old_output/
   ```

2. **Run comparison tests**:
   ```bash
   julia --project=. tests/compare_outputs.jl
   ```

3. **Investigate any differences**:
   - Check if differences are due to numerical precision (acceptable)
   - Check if differences are due to different data (need to align)
   - Check if differences are due to bugs (need to fix)

#### Step 5.2: Data Quality Checks

Verify key properties of output data:
```julia
using CSV, DataFrames

bonds = CSV.read("data/output/bonds_full.csv", DataFrame)

# Check dimensions
@info "Bonds dataset: $(nrow(bonds)) rows × $(ncol(bonds)) columns"

# Check for missing key variables
@assert all(in.(["cusip", "date", "ret_exc", "duration"], Ref(names(bonds))))

# Check value ranges
@info "Return range: $(extrema(skipmissing(bonds.ret_exc)))"
@info "Duration range: $(extrema(skipmissing(bonds.duration)))"

# Check time coverage
@info "Date range: $(extrema(bonds.date))"
```

---

### Phase 6: Documentation & Cleanup (1 hour)

#### Step 6.1: Update Documentation

- [ ] Update README.md with any changes made during migration
- [ ] Add any new configuration options to SETUP.md
- [ ] Document any deviations from original pipeline
- [ ] Add troubleshooting tips based on migration experience

#### Step 6.2: Code Cleanup

- [ ] Remove any debugging code
- [ ] Add comments to complex functions
- [ ] Ensure consistent code style
- [ ] Remove any unused functions

#### Step 6.3: Create Migration Report

Document:
- What was changed from original
- Any issues encountered and solutions
- Performance differences (if any)
- Recommendations for future improvements

---

## Timeline Summary

| Phase | Time Estimate | Description |
|-------|---------------|-------------|
| 1. Project Structure | ✅ Complete | Directory setup, docs, config |
| 2. Extract Functions | 3-4 hours | Copy src/ functions to new project |
| 3. Migrate Scripts | 2-3 hours | Copy and adapt clean_data scripts |
| 4. Test Migration | 1-2 hours | Test functions and run pipeline |
| 5. Validation | 1-2 hours | Compare outputs, quality checks |
| 6. Documentation | 1 hour | Update docs, cleanup, report |
| **Total** | **8-12 hours** | Plus 5-9 hours pipeline runtime |

---

## Checklist for Completion

### Prerequisites
- [ ] Original project working and tested
- [ ] All required data available
- [ ] Julia, R, and dependencies installed

### Extraction
- [ ] All DataLoader functions extracted
- [ ] All Preprocessing functions extracted
- [ ] All Factor functions extracted
- [ ] All Portfolio functions extracted
- [ ] All Utility functions extracted

### Scripts
- [ ] All scripts copied
- [ ] Import statements updated
- [ ] Path references updated
- [ ] Config properly integrated

### Testing
- [ ] Individual functions tested
- [ ] Small-scale pipeline tested
- [ ] Full pipeline completed successfully
- [ ] Outputs compared and validated
- [ ] Data quality checks passed

### Finalization
- [ ] Documentation updated
- [ ] Code cleaned and commented
- [ ] Migration report created
- [ ] Ready for production use

---

## Next Actions

To continue the migration, the next immediate steps are:

1. **Start with DataLoader** (easiest):
   ```bash
   # Open both files side by side
   code "corp-bond-replication/src/utils/main.jl"
   code "corp-bond-data/src/data_loader.jl"

   # Copy the DataLoader module or functions
   ```

2. **Then Preprocessing** (most critical):
   - This is the largest and most important extraction
   - Take care to include all dependencies
   - Test thoroughly

3. **Then Factors and Portfolios**:
   - These are smaller and should be straightforward

4. **Finally Scripts**:
   - Should be mostly find-and-replace for paths

Would you like me to:
- Start extracting functions automatically?
- Create a more detailed extraction guide for a specific module?
- Create helper scripts to automate parts of the migration?
