/* ************************************************************************************************ */
/* This code cleans the various data issues in Trace Enhanced File 									*/
/* Logic of the cleaning procedure largely follows the discussion of Dick-Nielsen (2009) and (2014) */
/* Cleaning procedure takes care of Cancellation, Correction, Reversal and Double Counting          */
/* Code is also designed to handle both pre and post 2012/02/06 change in the Trace System			*/
/* Author: Qingyi (Freda) Song Drechsler															*/
/* Date:   Written and Tested in October 2017														*/
/* ************************************************************************************************ */
libname fisd  ('/wrds/mergent/sasdata/fisd' '/wrds/mergent/sasdata/naic');
libname trace  '/wrds/trace/sasdata/standard';
libname tracee '/wrds/trace/sasdata/enhanced';
libname mylib  '/scratch/cbs/cst';

/* ********************************* */
/* Step 0: Understanding Data Fields */
/* ********************************* */

proc sql;
 create table __trc_st_pre as select distinct trc_st, count(*) as nobs 
 from tracee.trace_enhanced (where=(trd_rpt_dt<'06FEB2012'd)) group by trc_st; quit;

proc sql;
 create table __trc_st_post as select distinct trc_st, count(*) as nobs 
 from tracee.trace_enhanced (where=(trd_rpt_dt>='06FEB2012'd)) group by trc_st; quit;

proc sql;
 create table __asof_cd_pre as select distinct asof_cd, count(*) as nobs
 from tracee.trace_enhanced (where=(trd_rpt_dt<'06FEB2012'd)) group by asof_cd; quit;

proc sql;
 create table __asof_cd_post as select distinct asof_cd, count(*) as nobs
 from tracee.trace_enhanced (where=(trd_rpt_dt>='06FEB2012'd)) group by asof_cd; quit;
*/

/* Pre TRC_ST
												 Obs    trc_st      nobs

                                                    1       C        1383219
                                                    2       T       96884273
                                                    3       W        1013858
*/

/* Post TRC_ST
                                                   Obs    trc_st        nobs

                                                    1       C         709997
                                                    2       R         709995
                                                    3       T       44429743
                                                    4       X         579515
                                                    5       Y          10092
*/

/* Pre AsOf_CD
                                                   Obs    asof_cd        nobs

                                                    1                94578545
                                                    2        A        3322823
                                                    3        D          78804
                                                    4        R        1299513
                                                    5        X           1665
*/

/* Post AsOf_CD
                                                   Obs    asof_cd        nobs

                                                    1                44504880
                                                    2        A        1923633
                                                    3        R          10829
*/

/* ************************************** */
/* Step 1: Post 2012/02/06 Data Structure */
/* ************************************** */

*** Num of Obs (Starting Sample): 46,439,342;

/* ************************************ */
/* 1.0 Parsing out Post 2012/02/06 Data */
/* ************************************ */
data post; set tracee.trace_enhanced; where cusip_id ne '' and trd_rpt_dt >= '06Feb2012'd; run;
*** Num of Obs: 46,391,079;

data post_TR; set post; where trc_st in ('T', 'R'); run; *** 45,092,247;
data post_XC; set post; where trc_st in ('X', 'C'); run; *** 1,288,826;
data post_Y;  set post; where trc_st in ('Y'); run; *** 10,006;

/* ************************************** */
/* 1.1 Remove Cancellation and Correction */
/* ************************************** */

* Match Cancellation and Correction using following 7 keys:
* Cusip_id, Execution Date and Time, Quantity, Price, Buy/Sell Indicator, Contra Party
* C and X records show the same MSG_SEQ_NB as the original record;
proc sql;
 create table _clean_post1 as select distinct a.*, b.trc_st as trc_st_xc
 from POST_TR as a left join POST_XC as b
 on a.cusip_id = b.cusip_id 
 and a.trd_exctn_dt = b.trd_exctn_dt
 and a.trd_exctn_tm = b.trd_exctn_tm
 and a.rptd_pr = b.rptd_pr
 and a.entrd_vol_qt = b.entrd_vol_qt
 and a.rpt_side_cd = b.rpt_side_cd
 and a.cntra_mp_id = b.cntra_mp_id
 and a.msg_seq_nb = b.msg_seq_nb;
quit;

* Remove the matched "Trade Report" observations;
data _clean_post1; set _clean_post1; where trc_st_xc = ''; drop trc_st_xc; run;
*** Num of Obs after cleaning Cancellation and Corrections:  43,803,799;

/* ******************** */
/* 1.2 Remove Reversals */
/* ******************** */

* Match Reversal using the same 7 keys:
* Cusip_id, Execution Date and Time, Quantity, Price, Buy/Sell Indicator, Contra Party
* R records show ORIG_MSG_SEQ_NB matching orignal record MSG_SEQ_NB;
proc sql;
 create table _clean_post2 as select distinct a.*, b.trc_st as trc_st_y
 from _clean_post1 as a left join post_Y as b
 on a.cusip_id = b.cusip_id 
 and a.trd_exctn_dt = b.trd_exctn_dt
 and a.trd_exctn_tm = b.trd_exctn_tm
 and a.rptd_pr = b.rptd_pr
 and a.entrd_vol_qt = b.entrd_vol_qt
 and a.rpt_side_cd = b.rpt_side_cd
 and a.cntra_mp_id = b.cntra_mp_id
 and a.msg_seq_nb = b.orig_msg_seq_nb;
quit;

data _clean_post2; set _clean_post2; where trc_st_y=''; drop trc_st_y; run;
*** Num of Obs after cleaning Reversals: 43,797,014;

********************************* 
* Summary of Cleaning of Step 1 *
* Starting Obs: 46,439,342		*
* Ending Obs:	43,797,014		*
* Pct Cleaned:  5.7% 			*
*********************************;


/* ************************************* */
/* Step 2: Pre 2012/02/06 Data Structure */
/* ************************************* */
*** Num of Obs (Starting Sample):  99,281,350;

/* ************************************ */
/* 2.0 Parsing out Post 2012/02/06 Data */
/* ************************************ */

data PRE; set tracee.trace_enhanced; where cusip_id ne '' and trd_rpt_dt < '06Feb2012'd; run;
*** Num of Obs: 99,281,350;

data pre_c; set PRE; where trc_st in ('C'); run; ***  1,383,219;
data pre_w; set PRE; where trc_st in ('W'); run; ***  1,013,858;
data pre_t; set PRE; where trc_st in ('T'); run; *** 96,884,273;


/* ********************************* */
/* 2.1 Remove Cancellation Cases (C) */
/* ********************************* */

* Match Cancellation by the 7 keys:
* Cusip_ID, Execution Date and Time, Quantity, Price, Buy/Sell Indicator, Contra Party
* C records show ORIG_MSG_SEQ_NB matching orignal record MSG_SEQ_NB;
proc sql;
 create table _clean_pre1 as select distinct a.*, b.trc_st as trc_st_c
 from PRE_T as a left join PRE_C as b
 on a.cusip_id=b.cusip_id
 and a.trd_exctn_dt = b.trd_exctn_dt
 and a.trd_exctn_tm = b.trd_exctn_tm
 and a.rptd_pr = b.rptd_pr
 and a.entrd_vol_qt = b.entrd_vol_qt
 and a.trd_rpt_dt = b.trd_rpt_dt
 and a.msg_seq_nb = b.orig_msg_seq_nb;
quit;

data _del_c; set _clean_pre1; where trc_st_c='C'; run; *** 1,356,948;
data _clean_pre1; set _clean_pre1; where trc_st_c =''; drop trc_st_c; run; *** 95,527,325;

*********************************** 
* Summary of Cleaning of Step 2.1 *
* Starting Obs: 99,281,350 		  *
* Ending Obs:	95,527,325		  *
* Pct Cleaned:  3.8% 			  *
***********************************;

* Alternative Test: whether one can drop any of the keys as msg_seq_nb should be sufficient;
/*proc sql;
 create table _clean_pre1_alt as select distinct a.*, b.trc_st as trc_st_c
 from PRE_T as a left join PRE_C as b
 on a.cusip_id=b.cusip_id
 and a.trd_exctn_dt = b.trd_exctn_dt
 and a.trd_exctn_tm = b.trd_exctn_tm
 and a.msg_seq_nb = b.orig_msg_seq_nb;
quit;

data _clean_pre1_alt; set _clean_pre1_alt; where trc_st_c=''; drop trc_st_c; run; *** 95,527,317 - Difference is only 8 obs;
*/;

* NOTE ON CANCELLATION (C) CASES: 
* Fewer obs canceled using this left join than the ones labeled as C in the original dataset. 
* No of TRC_ST = C in data = 1,383,219
* No of cases in _DEL_C = 1,356,948
* Reason: some TRC_ST=C cases show an ORIG_MSG_SEQ_NB that doesn't exist in the orignal dataset.
* Example: 
* Among TRC_ST=C samples, BOND_SYM_ID=AA.HM and TRD_EXCTN_DT=20011003 TRD_EXCTN_TM=9:25:54 and RPTD_PR=103.144999 has ORIG_MSG_SEQ_NB=0033378.
* In the orignal TRC_ST=T samples, no obs has this MSG_SEQ_NB. The one that appears to be the matching cancel record has MSG_SEQ_NB= 0001482.
* Therefore, this 0001482 record is not deleted from the sample;


/* ******************************* */
/* 2.2 Remove Correction Cases (W) */
/* ******************************* */

* NOTE: on a given day, a bond can have more than one round of correction
* One W to correct an older W, which then corrects the original T
* Before joining back to the T data, first need to clean out the W to handle the situation described above;
* The following section handles the chain of W cases;

*** Starting W Obs Num: 1,013,858;

* 2.2.1 Sort out all msg_seq_nb;
data __w_msg; set pre_w; keep cusip_id bond_sym_id trd_exctn_dt trd_exctn_tm msg_seq_nb flag;
flag='msg'; run;

* Sort out all mapped original msg_seq_nb;
data __w_omsg; set pre_w; keep cusip_id bond_sym_id trd_exctn_dt trd_exctn_tm orig_msg_seq_nb flag;
flag='omsg';
rename orig_msg_seq_nb = msg_seq_nb;
run;

data __w; set __w_omsg __w_msg; run;

* 2.2.2 Count the number of appearance (napp) of a msg_seq_nb: 
* If appears more than once then it is part of later correction;
proc sql;
 create table __w_napp as select distinct cusip_id, bond_sym_id, trd_exctn_dt, trd_exctn_tm, msg_seq_nb, count(*) as napp
 from __w group by cusip_id, bond_sym_id, trd_exctn_dt, trd_exctn_tm, msg_seq_nb;
quit;

* 2.2.3 Check whether one msg_seq_nb is associated with both msg and orig_msg or only to orig_msg;
* If msg_seq_nb appearing more than once is associated with only orig_msg - 
* It means that more than one msg_seq_nb is linked to the same orig_msg_seq_nb for correction. 
* Examples: cusip_id='362320AX1' and trd_Exctn_dt='04FEB2005'd (3 cases like this in total)
* If ntype=2 then a msg_seq_nb is associated with being both msg_seq_nb and orig_msg_seq_nb;
proc sql;
 create table __w_mult as select distinct cusip_id, bond_sym_id, trd_exctn_dt, trd_exctn_tm, msg_seq_nb, flag from __w; quit;
proc sql;
 create table __w_mult1 as select distinct cusip_id, bond_sym_id, trd_exctn_dt, trd_exctn_tm, msg_seq_nb, count(*) as ntype 
 from __w_mult group by cusip_id, trd_exctn_dt, trd_exctn_tm, msg_seq_nb;
quit;

* 2.2.4 Combine the npair and ntype info;
proc sql;
 create table __w_comb as select distinct a.*, b.ntype
 from __w_napp as a left join __w_mult1 as b
 on a.cusip_id=b.cusip_id and a.trd_exctn_dt=b.trd_exctn_dt and a.trd_exctn_tm=b.trd_exctn_tm and a.msg_seq_nb=b.msg_seq_nb
 order by a.cusip_id, a.trd_exctn_dt, a.trd_exctn_tm;
quit;

* Map back by matching CUSIP Excution Date and Time to remove msg_seq_nb that appears more than once;
* If napp=1 or (napp>1 but ntype=1);
proc sql;
 create table __w_keep as select distinct a.*, b.flag
 from __w_comb (where=(napp=1 or (napp>1 and ntype=1))) as a inner join __w as b
 on a.cusip_id=b.cusip_id and a.trd_exctn_dt=b.trd_exctn_dt and a.trd_exctn_tm=b.trd_exctn_tm
 and a.msg_seq_nb=b.msg_seq_nb
 order by a.cusip_id, a.trd_exctn_dt, a.trd_exctn_tm;
quit;

*2.2.5 Caluclate no of pair of records;
proc sql; 
 create table __w_keep as select distinct *, count(*)/2 as npair 
 from __w_keep group by cusip_id, trd_exctn_dt, trd_exctn_tm
 order by cusip_id, trd_exctn_dt, trd_exctn_tm;
quit;

* For records with only one pair of entry at a given time stamp - transpose using the flag information;
proc transpose data = __w_keep out= __w_keep1 ;
where npair=1;
by cusip_id trd_exctn_dt trd_exctn_tm;
var msg_seq_nb;
id flag;
run;

data __w_keep1; set __w_keep1; drop _name_ _label_; rename msg=msg_seq_nb omsg=orig_msg_seq_nb; run;

* For records with more than one pair of entry at a given time stamp - join back the original msg_seq_nb;
proc sql;
 create table __w_keep2 as select distinct a.cusip_id, a.bond_sym_id, a.trd_exctn_dt, a.trd_exctn_tm, a.msg_seq_nb, b.orig_msg_seq_nb
 from __w_keep (where=(flag='msg' and npair>1)) as a left join pre_w as b
 on a.cusip_id=b.cusip_id and a.trd_exctn_dt=b.trd_exctn_dt and a.trd_exctn_tm=b.trd_exctn_tm 
 and a.msg_seq_nb=b.msg_seq_nb;
quit;

data __w_clean; set __w_keep1 __w_keep2; drop bond_sym_id; run;

* 2.2.6 Join back to get all the other information;
proc sql;
 create table _w_clean as select distinct a.*, b.*
 from __w_clean as a left join pre_w (drop=orig_msg_seq_nb) as b
 on a.cusip_id=b.cusip_id and a.trd_exctn_dt = b.trd_exctn_dt and a.trd_exctn_tm = b.trd_exctn_tm and a.msg_seq_nb = b.msg_seq_nb;
quit;


/* 2.2.7 Match up with Trade Record data to delete the matched T record */;
* Matching by Cusip_ID, Date, and MSG_SEQ_NB;
* W records show ORIG_MSG_SEQ_NB matching orignal record MSG_SEQ_NB;
proc sql;
 create table _clean_pre2 as select distinct a.*, 
 b.trc_st as trc_st_w, b.msg_seq_nb as mod_msg_seq_nb, b.orig_msg_seq_nb as mod_orig_msg_seq_nb
 from _clean_pre1 as a left join _w_clean as b
 on a.cusip_id = b.cusip_id
 and a.trd_exctn_dt = b.trd_exctn_dt
 and a.msg_seq_nb = b.orig_msg_seq_nb;
quit; ***   95,527,345;

data _del_w; set _clean_pre2; where trc_st_w = 'W'; run; *** 948,873;

* Delete matched T records;
data _clean_pre2; set _clean_pre2; where trc_st_w =''; drop trc_st_w MOD_msg_seq_nb MOD_orig_msg_seq_nb; run; ***   94,578,472;
 
* Replace T records with corresponding W records;
* Filter out W records with valid matching T from the previous step;
proc sql;
 create table _rep_w as select distinct a.*, b.trc_st_w, b.MOD_msg_seq_nb, b.MOD_orig_msg_seq_nb
 from _w_clean as a left join _del_w as b
 on a.cusip_id = b.cusip_id
 and a.trd_exctn_dt = b.trd_exctn_dt
 and a.msg_seq_nb = b.mod_msg_seq_nb;
quit;

data _rep_w; set _rep_w; where trc_st_w = 'W'; drop trc_st_w MOD_orig_msg_seq_nb Mod_msg_seq_nb; run; ***  948,038;

proc sort data = _rep_w out=_rep_w nodupkey;
	by cusip_id trd_exctn_dt msg_seq_nb orig_msg_seq_nb rptd_pr entrd_vol_qt;
run; ***  948,038;

* Combine the cleaned T records and correct replacement W records;
data _clean_pre3; set _clean_pre2 _rep_w; run; ***   95,526,510;

*********************************** 
* Summary of Cleaning of Step 2.2 *
* Starting Obs: 95,527,325 		  *
* Ending Obs:	95,526,510		  *
* Pct Cleaned:  0.0% 			  *
***********************************;


/* ***************** */
/* 2.3 Reversal Case */
/* ***************** */
data _rev_header; set _clean_pre3; where asof_cd ='R'; 
	keep cusip_id bond_sym_id trd_exctn_dt trd_exctn_tm trd_rpt_dt trd_rpt_tm entrd_vol_qt rptd_pr rpt_side_cd cntra_mp_id;
run; *** 1,276,503;

* Option A: Match by all 7 keys: CUSIP_ID, Execution Date and Time, Vol, Price, B/S and C/D;
proc sort data = _rev_header; 
 by cusip_id bond_sym_id trd_exctn_dt trd_exctn_tm entrd_vol_qt rptd_pr rpt_side_cd cntra_mp_id trd_rpt_dt trd_rpt_tm;
run; 

data _rev_header7; set _rev_header; 
	seq+1;
	by cusip_id bond_sym_id trd_exctn_dt trd_exctn_tm entrd_vol_qt rptd_pr rpt_side_cd cntra_mp_id;
	if first.cntra_mp_id then seq=1;
run;

* Option B: Match by only 6 keys: CUSIP_ID, Execution Date, Vol, Price, B/S and C/D (remove the time dimension);
proc sort data = _rev_header; 
 by cusip_id bond_sym_id trd_exctn_dt entrd_vol_qt rptd_pr rpt_side_cd cntra_mp_id trd_exctn_tm trd_rpt_dt trd_rpt_tm;
run;

data _rev_header6; set _rev_header; 
	seq+1;
	by cusip_id bond_sym_id trd_exctn_dt entrd_vol_qt rptd_pr rpt_side_cd cntra_mp_id;
	if first.cntra_mp_id then seq=1;
run;

* Create the same ordering among the non-reversal records;
* Remove records that are R (reversal) D (Delayed dissemination) and X (delayed reversal);
data _clean_pre4; set _clean_pre3; where asof_cd not in ('R', 'X', 'D'); run; ***  94,169,538;

data _clean_pre4_header; set _clean_pre4; 
	keep cusip_id bond_sym_id trd_exctn_dt trd_exctn_tm entrd_vol_qt rptd_pr rpt_side_cd cntra_mp_id trd_rpt_dt trd_rpt_tm msg_seq_nb;
run;

* Match by all 7 keys;
proc sort data = _clean_pre4_header;
  by cusip_id bond_sym_id trd_exctn_dt trd_exctn_tm entrd_vol_qt rptd_pr rpt_side_cd cntra_mp_id trd_rpt_dt trd_rpt_tm msg_seq_nb;
run;

data _clean_pre4_header; set _clean_pre4_header; 
	seq7+1;
	by cusip_id bond_sym_id trd_exctn_dt trd_exctn_tm entrd_vol_qt rptd_pr rpt_side_cd cntra_mp_id;
	if first.cntra_mp_id then seq7=1;
run;

* Match by 6 keys (excluding execution time);
proc sort data = _clean_pre4_header;
  by cusip_id bond_sym_id trd_exctn_dt entrd_vol_qt rptd_pr rpt_side_cd cntra_mp_id trd_exctn_tm trd_rpt_dt trd_rpt_tm msg_seq_nb;
run;

data _clean_pre4_header; set _clean_pre4_header; 
	seq6+1;
	by cusip_id bond_sym_id trd_exctn_dt entrd_vol_qt rptd_pr rpt_side_cd cntra_mp_id;
	if first.cntra_mp_id then seq6=1;
run;

* Join Reversal with Non-Reversal to delete the corresponding ones;
proc sql;
 create table _clean_pre5_header as select distinct a.*, b.seq as rev_seq7
 from _clean_pre4_header as a 
 left join _rev_header7 as b
 on a.cusip_id 		= b.cusip_id 
 and a.trd_exctn_dt = b.trd_exctn_dt
 and a.trd_exctn_tm = b.trd_exctn_tm
 and a.entrd_vol_qt = b.entrd_vol_qt
 and a.rptd_pr 		= b.rptd_pr
 and a.rpt_side_cd  = b.rpt_side_cd
 and a.cntra_mp_id  = b.cntra_mp_id
 and a.seq7			= b.seq;
quit;

proc sql;
 create table _clean_pre5_header as select distinct a.*, b.seq as rev_seq6
 from _clean_pre5_header as a 
 left join _rev_header6 as b
 on a.cusip_id 		= b.cusip_id 
 and a.trd_exctn_dt = b.trd_exctn_dt
 and a.entrd_vol_qt = b.entrd_vol_qt
 and a.rptd_pr 		= b.rptd_pr
 and a.rpt_side_cd  = b.rpt_side_cd
 and a.cntra_mp_id  = b.cntra_mp_id
 and a.seq6			= b.seq;
quit;

data _rev_matched7; set _clean_pre5_header; where rev_seq7 ne .; run;
*** If matching using all 7 keys 1,101,495 out of 1,276,685 reversal records were matched (86%);
data _rev_matched6; set _clean_pre5_header; where rev_seq6 ne .; run;
*** If matching using 6 keys 1,203,771 out of 1,276,685 reversal records were matched (94%);

* As 6 key matching has a higher record of finding reversal match, use the 6 keys results now;
data _clean_pre5_header; set _clean_pre5_header;
	where rev_seq6=.;
	drop rev_seq6 rev_seq7 seq7;
run; ***   92,956,225;

proc sql;
 create table _clean_pre5 as select distinct a.*
 from _clean_pre4 as a , _clean_pre5_header as b
 where a.cusip_id=b.cusip_id
 and a.trd_exctn_dt = b.trd_exctn_dt
 and a.trd_exctn_tm = b.trd_exctn_tm
 and a.entrd_vol_qt = b.entrd_vol_qt
 and a.rptd_pr 		= b.rptd_pr
 and a.rpt_side_cd  = b.rpt_side_cd
 and a.cntra_mp_id  = b.cntra_mp_id
 and a.msg_seq_nb 	= b.msg_seq_nb
 and a.trd_rpt_dt   = b.trd_rpt_dt
 and a.trd_rpt_tm 	= b.trd_rpt_tm;
quit; ***   92,965,767;

*********************************** 
* Summary of Cleaning of Step 2.3 *
* Starting Obs: 95,516,442		  *
* Ending Obs:	92,965,767		  *
* Pct Cleaned:  2.7% 			  *
***********************************;

*********************************** 
* Summary of Cleaning of Entire 2 *
* Starting Obs: 99,281,350		  *
* Ending Obs:	92,965,767		  *
* Pct Cleaned:  6.4% 			  *
***********************************;


/* Combine the pre and post data togetehr */;
data _clean; set _clean_pre5 _clean_post2; run; ***  136,762,781;


/* ******************************** */
/* Step 3: Clean Agency Transaction */
/* ******************************** */

* 3.1 Remove trades double reported by both buy and sell of the inter-dealer trade;
data _agency_s; set _clean;
where rpt_side_cd = 'S' and cntra_mp_id = 'D';
run; ***  35,847,900;

data _agency_b; set _clean;
where rpt_side_cd = 'B' and cntra_mp_id = 'D';
run; *** 33,642,126;

* Match B and S records by using CUSIP_ID, Trd_exctn_dt, price, vol;
* Do not match by trd_exctn_tm as it is self-reported and hence is less error free;
proc sql;
 create table _agency_bnodup as select distinct a.*
 from _agency_b as a left join _agency_s as b
 on a.cusip_id = b.cusip_id
 and a.trd_exctn_dt = b.trd_exctn_dt
 and a.rptd_pr = b.rptd_pr
 and a.entrd_vol_qt = b.entrd_vol_qt
 having b.rpt_side_cd = '';
quit;

* Cleaned of double counting = (CNTRA_MP_ID=C trades) 
                             + (CNTRA_MP_ID=D sells) 
							 + (Unmatched CNTRA_MP_ID=D buys);
* Some calls to remove all inter-dealer buys completely, regardless of matching or not;

data _clean_ag1; 
	set _clean (where=(cntra_mp_id='C')) _agency_s _agency_bnodup;
run; *** 105,524,984;


********************************* 
* Summary of Cleaning of Step 3 *
* Starting Obs: 136,753,239		*
* Ending Obs:	105,524,984	    *
* Pct Cleaned:  22.8% 			*
*********************************;

********************************* 
* Summary of Entire Procedure	*
* Starting Obs: 145,720,692		*
* Ending Obs:	105,524,984		*
* Pct Cleaned:  27.6% 			*
*********************************;



* #########    BELOW CODE NOT PART OF FILTER -- ONLY FOR SAVING TO FILE SYSTEM   ##############  ;

PROC SQL;
CREATE TABLE mylib.trace_prices AS
SELECT cusip_id , trd_exctn_dt , trd_exctn_tm , entrd_vol_qt , rptd_pr 
FROM _clean_ag1;
RUN;
QUIT;


PROC SQL;
CREATE TABLE mylib.trace_prices_2024 AS
SELECT * 
FROM mylib.trace_prices 
WHERE  trd_exctn_dt>'01Jan2024'd;
RUN;
QUIT;


