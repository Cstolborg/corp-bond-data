# Data Requirements

This document describes all required data sources and how to obtain them for the corporate bond data pipeline.

## Overview

The pipeline requires data from several sources:
1. **WRDS** (Wharton Research Data Services) - Primary source
2. **TRACE** - Corporate bond trading data
3. **ICE** (Optional) - Additional bond pricing
4. **Warga** (Optional) - Historical data for out-of-sample testing

## Required WRDS Access

You need a WRDS account with access to:
- **TRACE** (Trade Reporting and Compliance Engine)
- **Mergent FISD** (Fixed Income Securities Database)
- **CRSP** (Bond-equity links)
- **Fama-French Factors**

## Data Files Required

### 1. TRACE Intraday Data

**File**: `data/trace/trace_prices.sas7bdat`

**Source**: WRDS TRACE database

**Description**: Intraday corporate bond trading data with prices and volumes

**How to obtain**:
```python
# Use the provided Python script
python scripts/wrds_get_bond_rets.py
```

Or manually from WRDS web interface:
1. Go to WRDS → TRACE → Enhanced
2. Select date range: 2002-01-01 to 2024-04-30
3. Variables needed: `cusip_id`, `trd_exctn_dt`, `trd_exctn_tm`, `rptd_pr`, `entrd_vol_qt`
4. Export as SAS format
5. Save to `data/trace/trace_prices.sas7bdat`

**Size**: ~500 MB - 2 GB depending on time period

**Frequency**: Daily (update quarterly)

---

### 2. FISD Bond Characteristics

**Files**: Accessed via WRDS SAS library (no manual download needed)

**Source**: Mergent FISD

**Tables required**:
- `fisd.fisd_mergedissue` - Bond issue characteristics
- `fisd.fisd_mergedrating` - Credit ratings history
- `fisd.fisd_mergedamtout` - Amount outstanding

**Variables needed**:
- `cusip`, `issuer_id`, `issue_id`
- `maturity`, `offering_date`, `dated_date`
- `coupon`, `coupon_type`
- `convertible`, `bond_type`
- `rating_date`, `rating`
- `amount_outstanding`

**Access**: Automatically loaded by pipeline using SASLib

---

### 3. CRSP Bond-Equity Link

**File**: `data/wrds/bondcrsp_link.sas7bdat`

**Source**: WRDS CRSP

**Description**: Links bond CUSIPs to equity PERMNOs

**How to obtain**:
```python
# Use wrds_get_bond_rets.py or manual download
```

Or from WRDS:
1. Go to WRDS → CRSP → Bond
2. Download `crsp.bondcrsp_link` table
3. Save to `data/wrds/bondcrsp_link.sas7bdat`

**Size**: ~50 MB

---

### 4. Fama-French Factors

**File**: `data/wrds/ff_daily.csv`

**Source**: WRDS Fama-French

**How to obtain**:
```python
# Use wrds_get_bond_rets.py
```

Or manually:
1. Go to WRDS → Fama-French → Daily Factors
2. Select: `mktrf`, `smb`, `hml`, `rf`, `umd`
3. Date range: 1960-01-01 to present
4. Export as CSV
5. Save to `data/wrds/ff_daily.csv`

**Size**: ~5 MB

---

### 5. Treasury Yield Curve Parameters (GSW)

**File**: `data/output/gsw.csv`

**Source**: Federal Reserve / Gürkaynak-Sack-Wright

**Description**: Daily treasury spot curve parameters

**How to obtain**:
1. Download from Federal Reserve website:
   - https://www.federalreserve.gov/data/nominal-yield-curve.htm
2. Or use: https://www.federalreserve.gov/econresdata/researchdata/feds200628_1.html
3. Format: Date, beta0, beta1, beta2, tau1, beta3, tau2
4. Save to `data/output/gsw.csv`

**Alternative**: Extract from original project's `scripts/scientific_replication/data/gsw.csv`

**Size**: ~2 MB

**Frequency**: Daily

---

### 6. Bond-Equity Link Table

**File**: `data/BondEqLink.csv`

**Source**: Manually compiled or from WRDS

**Description**: Additional CUSIP to PERMNO/GVKEY mappings

**Format**:
```csv
cusip,permno,gvkey,link_date
...
```

**Note**: This is supplementary to CRSP bondcrsp_link

---

### 7. ICE Bond Data (Optional)

**File**: `data/ice_new/ICE_GI00.csv`

**Source**: ICE Data Services (subscription required)

**Description**: End-of-month bond prices from ICE

**Required for**: `preprocess_new_ice.jl` script

**Variables**:
- `cusip`, `date`, `price`, `yield`
- Bond characteristics (coupon, maturity, rating)

**Note**: Not required for basic TRACE pipeline

---

### 8. Warga Historical Data (Optional)

**Source**: WRDS Historical Bond Database

**Required for**: `create_datasets_oos_warga.jl` (out-of-sample testing)

**Description**: Pre-2002 corporate bond data

**How to obtain**: Available through WRDS historical databases

---

## Data Directory Structure

After downloading all required data, your directory should look like:

```
data/
├── trace/
│   ├── trace_prices.sas7bdat          (Required: Main TRACE data)
│   └── update 13-01-2025/              (Optional: For incremental updates)
├── wrds/
│   ├── bondcrsp_link.sas7bdat         (Required: Bond-equity link)
│   └── ff_daily.csv                    (Required: Fama-French factors)
├── ice_new/
│   └── ICE_GI00.csv                    (Optional: ICE data)
├── BondEqLink.csv                      (Required: Additional bond-equity links)
└── output/
    ├── gsw.csv                         (Required: Treasury parameters)
    └── [pipeline outputs will go here]
```

## Data Size Summary

| File | Size | Required | Frequency |
|------|------|----------|-----------|
| trace_prices.sas7bdat | 500 MB - 2 GB | Yes | Quarterly |
| bondcrsp_link.sas7bdat | 50 MB | Yes | Annually |
| ff_daily.csv | 5 MB | Yes | Daily |
| gsw.csv | 2 MB | Yes | Daily |
| BondEqLink.csv | Varies | Yes | As needed |
| ICE_GI00.csv | 100-500 MB | No | Monthly |

**Total Required**: ~600 MB - 2.1 GB
**Total with Optional**: ~700 MB - 2.6 GB

## Updating Data

### Regular Updates (Quarterly)

1. **Update TRACE data**:
   ```python
   # Modify date range in wrds_get_bond_rets.py
   python scripts/wrds_get_bond_rets.py
   ```

2. **Update Fama-French factors**:
   - Download latest FF daily factors from WRDS
   - Append to existing `ff_daily.csv`

3. **Update GSW parameters**:
   - Download latest from Federal Reserve
   - Append to `gsw.csv`

4. **Run update pipeline**:
   ```julia
   # Modify UPDATE_TIME_PERIOD in config/data_paths.jl
   julia --project=. scripts/update_datasets.jl
   ```

### Annual Updates

- **FISD characteristics**: Automatically updated via WRDS connection
- **Bond-equity links**: Download latest bondcrsp_link
- **ICE data**: If using, download end-of-year update

## Data Quality Checks

Before running the pipeline, verify:

1. **File existence**:
   ```julia
   include("config/data_paths.jl")
   @assert isfile(TRACE_INTRADAY_FILE) "TRACE file not found"
   @assert isfile(BONDCRSP_LINK) "Bond link file not found"
   @assert isfile(GSW_FILE) "GSW file not found"
   ```

2. **Date ranges**:
   - TRACE: Should cover 2002-2024
   - FF factors: Should include full TRACE period
   - GSW: Should cover full TRACE period

3. **File formats**:
   - SAS files readable by SASLib.jl
   - CSVs properly formatted with headers

## Troubleshooting

**Problem**: Cannot read SAS files

**Solution**:
```julia
using SASLib
# Test reading
df = SASLib.readsas("data/trace/trace_prices.sas7bdat")
```
If fails, try re-exporting from WRDS or converting to CSV

**Problem**: Missing FISD data

**Solution**: Ensure WRDS credentials are set:
```bash
# Set environment variables
export WRDS_USERNAME="your_username"
export WRDS_PASSWORD="your_password"
```

**Problem**: Date format issues

**Solution**: Ensure dates in CSV files are in `YYYY-MM-DD` format

## Data License and Usage

- **WRDS data**: Subject to WRDS terms of service
- **Federal Reserve data**: Public domain
- **ICE data**: Subject to ICE Data Services license

Ensure you have appropriate permissions before sharing derived datasets.

## Contact for Data Issues

For WRDS access issues: wrds@wharton.upenn.edu
For pipeline data issues: [Your contact]
