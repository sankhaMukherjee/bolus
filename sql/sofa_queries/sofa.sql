-- ------------------------------------------------------------------
-- Title: Sequential Organ Failure Assessment (SOFA)
-- This query extracts the sequential organ failure assessment (formally: sepsis-related organ failure assessment).
-- This score is a measure of organ failure for patients in the ICU.
-- The score is calculated on the first day of each ICU patients' stay.
-- ------------------------------------------------------------------

-- Reference for SOFA:
--    Jean-Louis Vincent, Rui Moreno, Jukka Takala, Sheila Willatts, Arnaldo De Mendonça,
--    Hajo Bruining, C. K. Reinhart, Peter M Suter, and L. G. Thijs.
--    "The SOFA (Sepsis-related Organ Failure Assessment) score to describe organ dysfunction/failure."
--    Intensive care medicine 22, no. 7 (1996): 707-710.

-- Variables used in SOFA:
--  GCS, MAP, FiO2, Ventilation status (sourced from CHARTEVENTS)
--  Creatinine, Bilirubin, FiO2, PaO2, Platelets (sourced from LABEVENTS)
--  Dobutamine, Epinephrine, Norepinephrine (sourced from INPUTEVENTS_MV and INPUTEVENTS_CV)
--  Urine output (sourced from OUTPUTEVENTS)

-- The following views required to run this query:
--  1) uofirstday - generated by urine-output-first-day.sql
--  2) vitalsfirstday - generated by vitals-first-day.sql
--  3) gcsfirstday - generated by gcs-first-day.sql
--  4) labsfirstday - generated by labs-first-day.sql
--  5) bloodgasfirstdayarterial - generated by blood-gas-first-day-arterial.sql
--  6) echodata - generated by echo-data.sql
--  7) ventdurations - generated by ventilation-durations.sql

-- Note:
--  The score is calculated for *all* ICU patients, with the assumption that the user will subselect appropriate ICUSTAY_IDs.
--  For example, the score is calculated for neonates, but it is likely inappropriate to actually use the score values for these patients.

DROP TABLE IF EXISTS MP_SOFA CASCADE;
CREATE TABLE MP_SOFA AS
-- generate a charttime for every hour

with co_stg as
(
  select icustay_id, hadm_id
  , date_trunc('hour', intime) as intime
  , outtime
  , generate_series
  (
    -24,
    ceil(extract(EPOCH from outtime-intime)/60.0/60.0)::INTEGER
  ) as hr
  from icustays
)
-- add in the charttime column
, co as
(
  select icustay_id, hadm_id, intime, outtime
  , hr*(interval '1' hour) + intime - interval '1' hour as starttime
  , hr*(interval '1' hour) + intime as endtime
  , hr
  from co_stg
)
, pafi as
(
  -- join blood gas to ventilation durations to determine if patient was vent
  select ie.icustay_id
  , bg.charttime
  -- because pafi has an interaction between vent/PaO2:FiO2, we need two columns for the score
  -- it can happen that the lowest unventilated PaO2/FiO2 is 68, but the lowest ventilated PaO2/FiO2 is 120
  -- in this case, the SOFA score is 3, *not* 4.
  , case when vd.icustay_id is null then pao2fio2ratio else null end PaO2FiO2Ratio_novent
  , case when vd.icustay_id is not null then pao2fio2ratio else null end PaO2FiO2Ratio_vent
  from icustays ie
  inner join mp_bg_art_sofa bg
    on ie.hadm_id = bg.hadm_id
    and bg.charttime between ie.intime and ie.outtime
  left join ventdurations vd
    on ie.icustay_id = vd.icustay_id
    and bg.charttime >= vd.starttime
    and bg.charttime <= vd.endtime
)
-- get minimum blood pressure from chartevents
, bp as
(
  select ce.icustay_id
    , ce.charttime
    , min(valuenum) as MeanBP_min
  from chartevents ce
  -- exclude rows marked as error
  where ce.error IS DISTINCT FROM 1
  and ce.itemid in
  (
  -- MEAN ARTERIAL PRESSURE
  456, --"NBP Mean"
  52, --"Arterial BP Mean"
  6702, --	Arterial BP Mean #2
  443, --	Manual BP Mean(calc)
  220052, --"Arterial Blood Pressure mean"
  220181, --"Non Invasive Blood Pressure mean"
  225312  --"ART BP mean"
  )
  and valuenum > 0 and valuenum < 300
  group by ce.icustay_id, ce.charttime
)
-- cumulative UO for the hour
, uo as
(
  select
  -- patient identifiers
    oe.icustay_id
  , oe.charttime
  -- volumes associated with urine output ITEMIDs
  -- note we consider input of GU irrigant as a negative volume
  , sum(case when oe.itemid = 227489 then -1*oe.value
      else oe.value end) as UrineOutput
  from outputevents oe
  where oe.iserror IS DISTINCT FROM 1
  and oe.icustay_id is not null
  and itemid in
  (
  -- these are the most frequently occurring urine output observations in CareVue
  40055, -- "Urine Out Foley"
  43175, -- "Urine ."
  40069, -- "Urine Out Void"
  40094, -- "Urine Out Condom Cath"
  40715, -- "Urine Out Suprapubic"
  40473, -- "Urine Out IleoConduit"
  40085, -- "Urine Out Incontinent"
  40057, -- "Urine Out Rt Nephrostomy"
  40056, -- "Urine Out Lt Nephrostomy"
  40405, -- "Urine Out Other"
  40428, -- "Urine Out Straight Cath"
  40086,--	Urine Out Incontinent
  40096, -- "Urine Out Ureteral Stent #1"
  40651, -- "Urine Out Ureteral Stent #2"

  -- these are the most frequently occurring urine output observations in CareVue
  226559, -- "Foley"
  226560, -- "Void"
  226561, -- "Condom Cath"
  226584, -- "Ileoconduit"
  226563, -- "Suprapubic"
  226564, -- "R Nephrostomy"
  226565, -- "L Nephrostomy"
  226567, --	Straight Cath
  226557, -- R Ureteral Stent
  226558, -- L Ureteral Stent
  227488, -- GU Irrigant Volume In
  227489  -- GU Irrigant/Urine Volume Out
  )
  group by oe.icustay_id, oe.charttime
)
-- maximum labs: creatinine, bilirubin. minimum: platelets
, labs as
(
  SELECT le.hadm_id, le.charttime
  -- add in some sanity checks on the values
  -- the where clause below requires all valuenum to be > 0, so these are only upper limit checks
  , max(CASE WHEN itemid = 50885 and valuenum <=   150 THEN valuenum ELSE NULL end) as bilirubin-- mg/dL 'BILIRUBIN'
  , max(CASE WHEN itemid = 50912 and valuenum <=   150 THEN valuenum ELSE NULL end) as creatinine-- mg/dL 'CREATININE'
  , min(CASE WHEN itemid = 51265 and valuenum <= 10000 THEN valuenum ELSE NULL end) as platelet -- K/uL 'PLATELET'
  FROM labevents le
  WHERE le.ITEMID in
  (
    -- comment is: LABEL | CATEGORY | FLUID | NUMBER OF ROWS IN LABEVENTS
    50885, -- BILIRUBIN, TOTAL | CHEMISTRY | BLOOD | 238277
    50912, -- CREATININE | CHEMISTRY | BLOOD | 797476
    51265 -- PLATELET COUNT | HEMATOLOGY | BLOOD | 778444
  )
  AND valuenum IS NOT null AND valuenum > 0 -- lab values cannot be 0 and cannot be negative
  GROUP BY le.hadm_id, le.charttime
)
, mini_agg as
(
  select co.icustay_id, co.hr
  -- vitals
  , min(bp.MeanBP_min) as MeanBP_min
  -- gcs
  , min(gcs.GCS) as GCS_min
  -- uo
  , sum(uo.urineoutput) as UrineOutput
  -- labs
  , max(labs.bilirubin) as bilirubin_max
  , max(labs.creatinine) as creatinine_max
  , min(labs.platelet) as platelet_min
  from co
  left join bp
    on co.icustay_id = bp.icustay_id
    and co.starttime < bp.charttime
    and co.endtime >= bp.charttime
  left join mp_gcs_sofa gcs
    on co.icustay_id = gcs.icustay_id
    and co.starttime < gcs.charttime
    and co.endtime >= gcs.charttime
  left join uo
    on co.icustay_id = uo.icustay_id
    and co.starttime < uo.charttime
    and co.endtime >= uo.charttime
  left join labs
    on co.hadm_id = labs.hadm_id
    and co.starttime < labs.charttime
    and co.endtime >= labs.charttime
  group by co.icustay_id, co.hr
)
, scorecomp as
(
  select
      co.icustay_id
    , co.intime, co.outtime
    , co.hr
    , co.starttime, co.endtime
    , pafi.PaO2FiO2Ratio_novent
    , pafi.PaO2FiO2Ratio_vent
    , epi.vaso_rate as rate_epinephrine
    , nor.vaso_rate as rate_norepinephrine
    , dop.vaso_rate as rate_dopamine
    , dob.vaso_rate as rate_dobutamine
    , ma.MeanBP_min
    , ma.GCS_min
    -- uo
    , ma.urineoutput
    -- labs
    , ma.bilirubin_max
    , ma.creatinine_max
    , ma.platelet_min
  from co
  left join mini_agg ma
    on co.icustay_id = ma.icustay_id
    and co.hr = ma.hr
  left join pafi
    on co.icustay_id = pafi.icustay_id
    and pafi.charttime >  co.starttime
    and pafi.charttime <= co.endtime
  left join mp_epinephrine epi
    on co.icustay_id = epi.icustay_id
    and co.endtime > epi.starttime
    and co.endtime <= epi.endtime
  left join mp_norepinephrine nor
    on co.icustay_id = nor.icustay_id
    and co.endtime > nor.starttime
    and co.endtime <= nor.endtime
  left join mp_dopamine dop
    on co.icustay_id = dop.icustay_id
    and co.endtime > dop.starttime
    and co.endtime <= dop.endtime
  left join mp_dobutamine dob
    on co.icustay_id = dob.icustay_id
    and co.endtime > dob.starttime
    and co.endtime <= dob.endtime
)
, scorecalc as
(
  -- Calculate the final score
  -- note that if the underlying data is missing, the component is null
  -- eventually these are treated as 0 (normal), but knowing when data is missing is useful for debugging
  select scorecomp.*
  -- Respiration
  , case
      when PaO2FiO2Ratio_vent   < 100 then 4
      when PaO2FiO2Ratio_vent   < 200 then 3
      when PaO2FiO2Ratio_novent < 300 then 2
      when PaO2FiO2Ratio_novent < 400 then 1
      when coalesce(PaO2FiO2Ratio_vent, PaO2FiO2Ratio_novent) is null then null
      else 0
    end as respiration

  -- Coagulation
  , case
      when platelet_min < 20  then 4
      when platelet_min < 50  then 3
      when platelet_min < 100 then 2
      when platelet_min < 150 then 1
      when platelet_min is null then null
      else 0
    end as coagulation

  -- Liver
  , case
      -- Bilirubin checks in mg/dL
        when Bilirubin_Max >= 12.0 then 4
        when Bilirubin_Max >= 6.0  then 3
        when Bilirubin_Max >= 2.0  then 2
        when Bilirubin_Max >= 1.2  then 1
        when Bilirubin_Max is null then null
        else 0
      end as liver

  -- Cardiovascular
  , case
      when rate_dopamine > 15 or rate_epinephrine >  0.1 or rate_norepinephrine >  0.1 then 4
      when rate_dopamine >  5 or rate_epinephrine <= 0.1 or rate_norepinephrine <= 0.1 then 3
      when rate_dopamine >  0 or rate_dobutamine > 0 then 2
      when MeanBP_Min < 70 then 1
      when coalesce(MeanBP_Min, rate_dopamine, rate_dobutamine, rate_epinephrine, rate_norepinephrine) is null then null
      else 0
    end as cardiovascular

  -- Neurological failure (GCS)
  , case
      when (GCS_min >= 13 and GCS_min <= 14) then 1
      when (GCS_min >= 10 and GCS_min <= 12) then 2
      when (GCS_min >=  6 and GCS_min <=  9) then 3
      when  GCS_min <   6 then 4
      when  GCS_min is null then null
  else 0 end
    as cns

  -- Renal failure - high creatinine or low urine output
  , case
    when (Creatinine_Max >= 5.0) then 4
    when
      SUM(urineoutput) OVER (PARTITION BY icustay_id ORDER BY hr
      ROWS BETWEEN 24 PRECEDING AND 0 FOLLOWING) < 200
        then 4
    when (Creatinine_Max >= 3.5 and Creatinine_Max < 5.0) then 3
    when
      SUM(urineoutput) OVER (PARTITION BY icustay_id ORDER BY hr
      ROWS BETWEEN 24 PRECEDING AND 0 FOLLOWING) < 500
        then 3
    when (Creatinine_Max >= 2.0 and Creatinine_Max < 3.5) then 2
    when (Creatinine_Max >= 1.2 and Creatinine_Max < 2.0) then 1
    when coalesce
      (
        SUM(urineoutput) OVER (PARTITION BY icustay_id ORDER BY hr
        ROWS BETWEEN 24 PRECEDING AND 0 FOLLOWING)
        , Creatinine_Max
      ) is null then null
  else 0 end
    as renal
  from scorecomp
)
, score_final as
(
  select s.*
    -- Combine all the scores to get SOFA
    -- Impute 0 if the score is missing
   -- the window function takes the max over the last 24 hours
    , coalesce(
        MAX(respiration) OVER (PARTITION BY icustay_id ORDER BY HR
        ROWS BETWEEN 24 PRECEDING AND 0 FOLLOWING)
      ,0) as respiration_24hours
     , coalesce(
         MAX(coagulation) OVER (PARTITION BY icustay_id ORDER BY HR
         ROWS BETWEEN 24 PRECEDING AND 0 FOLLOWING)
        ,0) as coagulation_24hours
    , coalesce(
        MAX(liver) OVER (PARTITION BY icustay_id ORDER BY HR
        ROWS BETWEEN 24 PRECEDING AND 0 FOLLOWING)
      ,0) as liver_24hours
    , coalesce(
        MAX(cardiovascular) OVER (PARTITION BY icustay_id ORDER BY HR
        ROWS BETWEEN 24 PRECEDING AND 0 FOLLOWING)
      ,0) as cardiovascular_24hours
    , coalesce(
        MAX(cns) OVER (PARTITION BY icustay_id ORDER BY HR
        ROWS BETWEEN 24 PRECEDING AND 0 FOLLOWING)
      ,0) as cns_24hours
    , coalesce(
        MAX(renal) OVER (PARTITION BY icustay_id ORDER BY HR
        ROWS BETWEEN 24 PRECEDING AND 0 FOLLOWING)
      ,0) as renal_24hours

    , coalesce(
        MAX(respiration) OVER (PARTITION BY icustay_id ORDER BY HR
        ROWS BETWEEN 24 PRECEDING AND 0 FOLLOWING)
      ,0)
     + coalesce(
         MAX(coagulation) OVER (PARTITION BY icustay_id ORDER BY HR
         ROWS BETWEEN 24 PRECEDING AND 0 FOLLOWING)
      ,0)
     + coalesce(
        MAX(liver) OVER (PARTITION BY icustay_id ORDER BY HR
        ROWS BETWEEN 24 PRECEDING AND 0 FOLLOWING)
      ,0)
     + coalesce(
        MAX(cardiovascular) OVER (PARTITION BY icustay_id ORDER BY HR
        ROWS BETWEEN 24 PRECEDING AND 0 FOLLOWING)
      ,0)
     + coalesce(
        MAX(cns) OVER (PARTITION BY icustay_id ORDER BY HR
        ROWS BETWEEN 24 PRECEDING AND 0 FOLLOWING)
      ,0)
     + coalesce(
        MAX(renal) OVER (PARTITION BY icustay_id ORDER BY HR
        ROWS BETWEEN 24 PRECEDING AND 0 FOLLOWING)
      ,0)
    as SOFA_24hours
  from scorecalc s
)
select * from score_final
-- filter out all the rows before ICU admission that don't have any labs
-- this leaves us with patient data like:
-- 200001, hr=-12, MeanBP (is null), LAB_1, LAB_2
-- 200001, hr=0, MeanBP, LAB_1, LAB_2
-- ... rather than having a bunch of null rows from hr=-11 to hr=-1
where (hr >= 0) OR (coalesce(bilirubin_max, creatinine_max, platelet_min) is not null);
