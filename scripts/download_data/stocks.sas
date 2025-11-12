libname mylib  '/scratch/cbs/cst';

proc sql;
    create table mylib.stocks as
    select id, eom,  /* Primary keys */
	ret_exc as ret_eq, ret_exc_lead1m as ret_eq_lead
    from contrib.global_factor
    where excntry='USA' and ret_exc_lead1m is not missing and be_me is not missing
    and exch_main=1 and primary_sec=1 and common=1 and obs_main=1
    and date>'30Nov1975'd;
quit;

/* Exporting data files */
proc export data=mylib.stocks
    outfile="/scratch/cbs/cst/stocks.csv"
    dbms=csv REPLACE;
run;	