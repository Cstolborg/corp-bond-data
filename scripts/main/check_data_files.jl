"""
    check_data_files.jl

Check that all required data files are present before running create_datasets.jl

Usage:
    julia --project=. scripts/main/check_data_files.jl

Or include in REPL:
    include("scripts/main/check_data_files.jl")
    check_all_data_files()
"""

using Dates
using CSV
using DataFrames
using Downloads

# (Configuration no longer needed - checking main files only)

"""
    check_file_exists(filepath::String, description::String)

Check if a file exists and print status.
Returns true if file exists, false otherwise.
"""
function check_file_exists(filepath::String, description::String)
    if isfile(filepath)
        println("✓ Found: $description")
        println("  Path: $filepath")
        return true
    else
        println("✗ MISSING: $description")
        println("  Expected path: $filepath")
        return false
    end
end

"""
    download_gsw_params()

Download GSW (Gürkaynak-Sack-Wright) treasury yield curve parameters from Federal Reserve.
"""
function download_gsw_params()
    println("\nDownloading GSW treasury yield curve parameters from Federal Reserve...")

    try
        res = CSV.read(
            Downloads.download("https://www.federalreserve.gov/data/yield-curve-tables/feds200628.csv"),
            DataFrame;
            header=10,
            missingstring=["NA", "-999.99"]
        )

        # Process the data
        rename!(res, lowercase.(names(res)))
        select!(res, :date, Cols(startswith("beta")), Cols(startswith("tau")))
        replace!(res.tau2, missing=>0.0)
        dropmissing!(res)  # Missing values in all params in various dates such as 1991-03-29

        # Transform to monthly data
        sort!(res, :date)
        res.eom = Dates.lastdayofmonth.(res.date)
        res = combine(groupby(res, :eom), names(res, Not(:date)) .=> (x-> x[end]), renamecols=false)
        rename!(res, :eom => :date)

        # Save to file
        output_dir = "data/output"
        !isdir(output_dir) && mkpath(output_dir)

        output_file = joinpath(output_dir, "gsw.csv")
        CSV.write(output_file, res)

        println("✓ Successfully downloaded and saved GSW data")
        println("  File: $output_file")
        println("  Rows: $(nrow(res))")
        println("  Date range: $(minimum(res.date)) to $(maximum(res.date))")

        return true
    catch e
        println("✗ ERROR downloading GSW data: $e")
        return false
    end
end

"""
    check_all_data_files()

Check all required data files for create_datasets.jl pipeline.
Throws AssertionError if any required files are missing.
"""
function check_all_data_files()
    println("\n" * "="^80)
    println("Checking Data Files for create_datasets.jl Pipeline")
    println("="^80 * "\n")

    missing_files = String[]
    all_present = true

    # =========================================================================
    # REQUIRED INPUT FILES
    # =========================================================================

    println("REQUIRED INPUT FILES:")
    println("-" * "="^79 * "\n")

    # TRACE intraday data - check main file
    println("[1] TRACE Intraday Data")
    trace_main = "data/wrds/trace_prices.sas7bdat"
    if !check_file_exists(trace_main, "TRACE intraday trading data (SAS format)")
        push!(missing_files, trace_main)
        all_present = false
    end
    println()

    # FISD data files (now in data/wrds/)
    println("[2] FISD (Mergent) Bond Characteristics")
    fisd_issue = "data/wrds/fisd_issue.sas7bdat"
    if !check_file_exists(fisd_issue, "FISD issue characteristics")
        push!(missing_files, fisd_issue)
        all_present = false
    end
    println()

    println("[3] FISD Ratings")
    fisd_ratings = "data/wrds/fisd_ratings.sas7bdat"
    if !check_file_exists(fisd_ratings, "FISD time-varying credit ratings")
        push!(missing_files, fisd_ratings)
        all_present = false
    end
    println()

    println("[4] FISD Defaults")
    fisd_defaults = "data/wrds/fisd_defaults.sas7bdat"
    if !check_file_exists(fisd_defaults, "FISD default dates")
        push!(missing_files, fisd_defaults)
        all_present = false
    end
    println()

    println("[5] FISD Amount Outstanding")
    fisd_amt_out = "data/wrds/fisd_amt_out.sas7bdat"
    if !check_file_exists(fisd_amt_out, "FISD latest amount outstanding")
        push!(missing_files, fisd_amt_out)
        all_present = false
    end
    println()

    println("[6] FISD Amount Outstanding (Historical)")
    fisd_amt_hist = "data/wrds/fisd_amt_out_hist.sas7bdat"
    if !check_file_exists(fisd_amt_hist, "FISD historical amount outstanding")
        push!(missing_files, fisd_amt_hist)
        all_present = false
    end
    println()

    # WRDS/CRSP data
    println("[7] Bond-CRSP Link")
    bondcrsp_link = "data/wrds/bondcrsp_link.sas7bdat"
    if !check_file_exists(bondcrsp_link, "CUSIP to PERMNO/GVKEY mapping")
        push!(missing_files, bondcrsp_link)
        all_present = false
    end
    println()

    println("[8] Fama-French Daily Factors")
    ff_daily = "data/wrds/ff_daily.csv"
    if !check_file_exists(ff_daily, "Fama-French daily factors and risk-free rate")
        push!(missing_files, ff_daily)
        all_present = false
    end
    println()

    # Stocks data (created by stocks.sas)
    println("[9] Equity Returns Data")
    stocks = "data/wrds/stocks.csv"
    if !check_file_exists(stocks, "Equity returns (from stocks.sas)")
        push!(missing_files, stocks)
        all_present = false
    end
    println()

    # =========================================================================
    # GSW DATA (auto-download if missing)
    # =========================================================================

    println("\n" * "="^80)
    println("GSW TREASURY YIELD CURVE DATA:")
    println("-" * "="^79 * "\n")

    println("[10] GSW Treasury Yield Curve Parameters")
    gsw_file = "data/output/gsw.csv"
    if isfile(gsw_file)
        println("✓ Found: GSW treasury curve parameters")
        println("  Path: $gsw_file")
        file_mod_time = Dates.unix2datetime(mtime(gsw_file))
        println("  Last updated: $file_mod_time")

        # Check if file is older than 7 days
        days_old = Dates.value(Dates.now() - file_mod_time) / (1000 * 60 * 60 * 24)
        if days_old > 7
            println("  ⚠ File is $(round(days_old, digits=1)) days old. Refreshing...")
            download_gsw_params()
        else
            println("  ✓ File is up to date ($(round(days_old, digits=1)) days old)")
        end
    else
        println("✗ MISSING: GSW treasury curve parameters")
        println("  Downloading from Federal Reserve...")
        download_gsw_params()
    end
    println()

    # =========================================================================
    # OUTPUT DIRECTORY
    # =========================================================================

    println("\n" * "="^80)
    println("OUTPUT DIRECTORY:")
    println("-" * "="^79 * "\n")

    output_dir = "data/output"
    if isdir(output_dir)
        println("✓ Found: Output directory")
        println("  Path: $output_dir")
    else
        println("✗ MISSING: Output directory")
        println("  Creating: $output_dir")
        mkpath(output_dir)
        println("✓ Created: $output_dir")
    end
    println()

    # =========================================================================
    # SUMMARY
    # =========================================================================

    println("\n" * "="^80)
    println("SUMMARY")
    println("="^80 * "\n")

    if all_present
        println("✓ ALL REQUIRED FILES ARE PRESENT!")
        println("\nYou can now run the pipeline:")
        println("  julia --project=. scripts/main/create_datasets.jl")
        println()
        return true
    else
        println("✗ SOME REQUIRED FILES ARE MISSING!")
        println("\nMissing files:")
        for file in missing_files
            println("  - $file")
        end
        println("\nPlease download the missing files before running the pipeline.")
        println("See README.md or CLAUDE.md for download instructions.")
        println()

        # Throw AssertionError with list of missing files
        error_msg = "Missing $(length(missing_files)) required data file(s):\n" * join(missing_files, "\n")
        throw(AssertionError(error_msg))
    end
end

"""
    check_trace_file_info()

Print detailed information about the TRACE data file if it exists.
"""
function check_trace_file_info()
    trace_file = "data/wrds/trace_prices.sas7bdat"

    if !isfile(trace_file)
        println("TRACE file not found: $trace_file")
        return
    end

    println("\n" * "="^80)
    println("TRACE FILE INFORMATION")
    println("="^80 * "\n")

    file_size = filesize(trace_file)
    file_size_mb = round(file_size / 1024^2, digits=2)
    file_size_gb = round(file_size / 1024^3, digits=2)

    println("File: $trace_file")
    println("Size: $file_size_mb MB ($file_size_gb GB)")
    println("Last modified: $(Dates.unix2datetime(mtime(trace_file)))")
    println()
end

# Run checks if script is executed directly
if abspath(PROGRAM_FILE) == @__FILE__
    try
        result = check_all_data_files()
        check_trace_file_info()
        exit(0)
    catch e
        if e isa AssertionError
            println("\n" * "="^80)
            println("ERROR: Data validation failed")
            println("="^80)
            println(e.msg)
            println()
            exit(1)
        else
            rethrow(e)
        end
    end
end
