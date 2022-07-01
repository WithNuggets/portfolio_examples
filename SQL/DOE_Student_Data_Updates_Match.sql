-- Purpose of query
/* 
Each year, the Department of Education releases a file that district utilize to provide Student Data Updates to.
This allows for changes to student information after Survey windows are closed.
These updates are critical for end of year data as these students are compiled into how a school and district's overall grade for the year is calculated.
This query takes the base file uploaded into the SIS and then compares what is on the base file to what is in the SIS to discover changes.

SIS = Student Information System
*/

-- PULLING ACTIVE ENROLLMENTS AND WITHDRAWALS SINCE END OF SURVEY 3
-- Survey 2 and 3 are the two Surveys that are used by the Department of Education as for who counts in the end of year grade.
-- If a student is in Survey 2 AND 3, they will count for at least the district
-- This CTE looks at either the last enrollment for a withdrawn student or the active enrollment of the student
WITH last_enrollment AS
(
	SELECT
		DISTINCT z.student_id
		,z.fleid
		,z.start_date
		,z.end_date
		,z.drop_code
		,z.grade
		,z.school
		,z.school_num
		,CASE WHEN z.end_date IS NOT NULL THEN 'Y' ELSE 'N' END AS withdrawn
	FROM
		(
			SELECT
				s.student_id
				,s.custom_200000224 AS fleid
				,se.start_date
				,se.end_date
				,drop.title AS drop_code
				,gl.title AS grade
				,sc.title AS school
				,sc.custom_327 AS school_num
				,ROW_NUMBER() OVER (PARTITION BY se.student_id ORDER BY se.end_date DESC) AS rn
			FROM
				students s
				INNER JOIN student_enrollment se ON (se.student_id = s.student_id)
				LEFT JOIN florida_demographic_ofile o ON (o.student_local = s.student_id::varchar AND o.survey = '3' AND o.syear = '2122')
				INNER JOIN schools sc ON (sc.id = se.school_id)
				INNER JOIN school_gradelevels gl ON (gl.id = se.grade_id)
				LEFT JOIN student_enrollment_codes DROP ON (DROP.id = se.drop_code)
			WHERE
				(TO_CHAR(se.end_date, 'yyyymmdd') >= '20220218' OR se.end_date IS NULL) -- The enrollment end date needs to be after February 18th, the day Survey 3 ended or it needs to be active
                AND se.syear = '2021'
				AND COALESCE(se.custom_9, 'N') = 'N'
		) AS z
	WHERE
		(z.rn = 1 OR z.end_date IS NULL) -- Pulls last enrollment or the active enrollment
),

-- GETTING THE 10 CHARACTER STRING OF ESE CODES
-- The Department of Education file displays the student's diability codes as a 10 character string (students with no disability display as ZZZZZZZZZZ)
-- Pulling from the custom_field tables available in the SIS, the student's disability codes (if applicable) are pulled and then padded with Z until 10 characters are reached
ese_codes AS
(
	SELECT
		s.fleid
		,CONCAT(COALESCE(RPAD(STRING_AGG(prim.code, ''), 1, 'Z'), 'Z'), COALESCE(RPAD(STRING_AGG(other.code, '' ORDER BY other.code), 9, 'Z'), 'ZZZZZZZZZ')) AS code
	FROM
		last_enrollment s
		LEFT JOIN custom_field_log_entries ese ON (ese.source_id = s.student_id AND ese.field_id = 457) -- 457 is the ID associated with the log columns/entries related to disability
		LEFT JOIN custom_field_select_options type ON (type.id::varchar = ese.log_field6 AND type.code = 'A') -- SERVICE TYPE; A means that the disability is active
		LEFT JOIN custom_field_select_options prim ON (prim.id::varchar = ese.log_field3 AND ese.log_field4 = 'Y' AND type.code = 'A' AND ese.log_field12 IS NULL) -- PRIMARY CODE; Log_Field4 = 'Y' means that the disability code is considered the primary; Log_Field12 is the dismissal date
		LEFT JOIN custom_field_select_options other ON (other.id::varchar = ese.log_field3 AND COALESCE(ese.log_field4, 'N') != 'Y' AND type.code = 'A' AND ese.log_field12 IS NULL) -- OTHER CODE; Log_Field12 is the dismissal date
	GROUP BY s.fleid
),

-- PULLING THE ACTIVE DOP CODES
-- DOP = Drop Out Prevention; This can be for a variety of reasons such as attendance or academic issues
dop_code AS
(
	SELECT
		s.fleid
		,fieldoptioncode(dop.log_field1) AS program -- This pulls the abbreviation for the prevention program the student is in
		,CASE WHEN TO_CHAR(dop.log_field4::date, 'yyyymmdd') >= '20220218' THEN TO_CHAR(dop.log_field4::date, 'yyyymmdd') ELSE NULL END AS enroll_date
		,CASE WHEN TO_CHAR(dop.log_field5::date, 'yyyymmdd') >= '20220218' THEN TO_CHAR(dop.log_field5::date, 'yyyymmdd') ELSE NULL END AS drop_date
	FROM
		last_enrollment s
		LEFT JOIN custom_field_log_entries dop ON (dop.source_id = s.student_id AND dop.field_id = 312)
	WHERE
		dop.log_field2 = 'Y' -- This log_field denotes if the program is active
		AND dop.log_field5 IS NULL -- This log_field denotes the dismissal date
),

----- START OF CHANGE DATE PULLS FROM DATABASE_OBJECT_LOG -----

-- database_object_log captures all end user changes on the interface of the SIS

-- ZONED DISTRICT
zoned_district_change_date AS
(
	SELECT
		z.fleid
		,TO_CHAR(z.log_time::date, 'yyyymmdd') AS change_date
	FROM
		(
			SELECT
				ROW_NUMBER() OVER (PARTITION BY ol.student_id ORDER BY ol.log_time DESC) AS rn
				,ol.log_time
				,s.custom_200000224 AS fleid
			FROM
				database_object_log ol
				INNER JOIN users u ON (u.staff_id = ol.user_id)
				INNER JOIN students s ON (s.student_id = ol.student_id)
				INNER JOIN student_data_updates_temp du ON (du.fleid = s.custom_200000224)
			WHERE
				ol.action = 'UPDATE' -- Needs to be an UPDATE action
				AND ol.after LIKE '%CUSTOM_821%' -- This is the custom field that stores the student's zoned district
				AND TO_CHAR(ol.log_time::date, 'yyyymmdd') >= '20220218' -- Change needs to be after Survey 3 ended
		) AS z
	WHERE
		z.rn = 1 -- Pulls last change related to the field
),

-- ZONED SCHOOL
zoned_school_change_date AS
(
	SELECT
		z.fleid
		,TO_CHAR(z.log_time::date, 'yyyymmdd') AS change_date
	FROM
		(
			SELECT
				ROW_NUMBER() OVER (PARTITION BY ol.student_id ORDER BY ol.log_time DESC) AS rn
				,ol.log_time
				,s.custom_200000224 AS fleid
			FROM
				database_object_log ol
				INNER JOIN users u ON (u.staff_id = ol.user_id)
				INNER JOIN students s ON (s.student_id = ol.student_id)
				INNER JOIN student_data_updates_temp du ON (du.fleid = s.custom_200000224)
			WHERE
				ol.action = 'UPDATE' -- Needs to be an UPDATE action
				AND ol.after LIKE '%CUSTOM_822%' -- This is the custom field that stores the student's zoned school
				AND TO_CHAR(ol.log_time::date, 'yyyymmdd') >= '20220218' -- Change needs to be after Survey 3 ended
		) AS z
	WHERE
		z.rn = 1 -- Pulls last change related to the field
),

-- PRIMARY ESE
ese_prim_change_date AS
(
	SELECT
		z.fleid
		,TO_CHAR(z.log_time::date, 'yyyymmdd') AS change_date
	FROM
		(
			SELECT
				ROW_NUMBER() OVER (PARTITION BY ol.student_id ORDER BY ol.log_time DESC) AS rn
				,ol.log_time
				,s.custom_200000224 AS fleid
			FROM
				database_object_log ol
				INNER JOIN users u ON (u.staff_id = ol.user_id)
				INNER JOIN students s ON (s.student_id = ol.student_id)
				INNER JOIN student_data_updates_temp du ON (du.fleid = s.custom_200000224)
			WHERE
				ol.action = 'UPDATE' -- Needs to be an UPDATE action
				AND ol.after LIKE '%LOG_FIELD4%' -- This houses the change in the primary disability
				AND TO_CHAR(ol.log_time::date, 'yyyymmdd') >= '20220218' -- Change needs to be after Survey 3 ended
		) AS z
	WHERE
		z.rn = 1 -- Pulls last change related to the field
),

-- OTHER ESE
ese_other_change_date AS
(
	SELECT
		z.fleid
		,TO_CHAR(z.log_time::date, 'yyyymmdd') AS change_date
	FROM
		(
			SELECT
				ROW_NUMBER() OVER (PARTITION BY ol.student_id ORDER BY ol.log_time DESC) AS rn
				,ol.log_time
				,s.custom_200000224 AS fleid
			FROM
				database_object_log ol
				INNER JOIN users u ON (u.staff_id = ol.user_id)
				INNER JOIN students s ON (s.student_id = ol.student_id)
				INNER JOIN student_data_updates_temp du ON (du.fleid = s.custom_200000224)
			WHERE
				ol.action = 'UPDATE' -- Needs to be an UPDATE action
				AND ol.after LIKE '%LOG_FIELD6%' -- This houses the change in the secondary disabilities
				AND TO_CHAR(ol.log_time::date, 'yyyymmdd') >= '20220218' -- Change needs to be after Survey 3 ended
		) AS z
	WHERE
		z.rn = 1 -- Pulls last change related to the field
),

-- GRADE LEVEL
grade_level_change_date AS
(
	SELECT
		z.fleid
		,TO_CHAR(z.log_time::date, 'yyyymmdd') AS change_date
	FROM
		(
			SELECT
				ROW_NUMBER() OVER (PARTITION BY ol.student_id ORDER BY ol.log_time DESC) AS rn
				,ol.log_time
				,s.custom_200000224 AS fleid
			FROM
				database_object_log ol
				INNER JOIN users u ON (u.staff_id = ol.user_id)
				INNER JOIN students s ON (s.student_id = ol.student_id)
				INNER JOIN student_data_updates_temp du ON (du.fleid = s.custom_200000224)
			WHERE
				ol.action = 'UPDATE' -- Needs to be an UPDATE action
				AND ol.after LIKE '%GRADE_ID%' -- This houses the change in the primary grade level
				AND TO_CHAR(ol.log_time::date, 'yyyymmdd') >= '20220218' -- Change needs to be after Survey 3 ended
		) AS z
	WHERE
		z.rn = 1 -- Pulls last change related to the field
),

-- ELL CODE
ell_code_change_date AS
(
	SELECT
		z.fleid
		,TO_CHAR(z.log_time::date, 'yyyymmdd') AS change_date
	FROM
		(
			SELECT
				ROW_NUMBER() OVER (PARTITION BY ol.student_id ORDER BY ol.log_time DESC) AS rn
				,ol.log_time
				,s.custom_200000224 AS fleid
			FROM
				database_object_log ol
				INNER JOIN users u ON (u.staff_id = ol.user_id)
				INNER JOIN students s ON (s.student_id = ol.student_id)
				INNER JOIN student_data_updates_temp du ON (du.fleid = s.custom_200000224)
			WHERE
				ol.action = 'UPDATE' -- Needs to be an UPDATE action
				AND ol.after LIKE '%CUSTOM_626%' -- This houses the change in the English Language Learner code
				AND TO_CHAR(ol.log_time::date, 'yyyymmdd') >= '20220218' -- Change needs to be after Survey 3 ended
		) AS z
	WHERE
		z.rn = 1 -- Pulls last change related to the field
),

-- Combines the base file from Department of Education (table du) and what has been gathered in the previous CTEs from the SIS.
-- There are change columns for each component capable of being changed. If the value from the base file does not match the SIS, that column is marked with a 'Y'.
base_file AS
(
	SELECT
		du.record_id
		,du.district_of_enrollment
		,LPAD(du.school_of_enrollment, 4, '0') AS school_of_enrollment
		,du.student_last_name
		,du.student_first_name
		,du.fleid
		,du.date_of_birth
		,du.sex
		,du.race
		,du.full_year_school
		,du.full_year_district
		,du.ext_med
		,LPAD(du.zoned_district, 2, '0') AS doe_zoned_district
		,COALESCE(fieldoptioncode(s.custom_821), '00') AS focus_zoned_district
		,CASE WHEN LPAD(du.zoned_district, 2, '0') != COALESCE(fieldoptioncode(s.custom_821), '00') THEN 'Y' ELSE NULL END AS zoned_district_change
		,LPAD(du.zoned_school, 4, '0') AS doe_zoned_school
		,COALESCE(fieldoptioncode(s.custom_822), '0000') AS focus_zoned_school
		,CASE WHEN LPAD(du.zoned_school, 4, '0') != COALESCE(fieldoptioncode(s.custom_822), '0000') THEN 'Y' ELSE NULL END AS zoned_school_change
		,LPAD(du.grade_level, 2, '0') AS doe_grade_level
		,LPAD(se.grade, 2, '0') AS focus_grade_level
		,CASE WHEN LPAD(du.grade_level, 2, '0') != LPAD(se.grade, 2, '0') THEN 'Y' ELSE NULL END AS grade_level_change
		,CASE WHEN du.ese_code = '0' THEN NULL ELSE LEFT(du.ese_code, 1) END AS doe_primary_ese_code
		,CASE WHEN LEFT(ese.code, 1) = 'Z' THEN NULL ELSE LEFT(ese.code, 1) END AS focus_primary_ese_code
		,CASE WHEN (CASE WHEN du.ese_code = '0' THEN 'Z' ELSE LEFT(du.ese_code, 1) END) != LEFT(ese.code, 1) THEN 'Y' ELSE NULL END AS primary_ese_code_change
		,CASE WHEN du.ese_code = '0' THEN NULL ELSE SUBSTRING(du.ese_code, 2) END AS doe_other_ese_code
		,CASE WHEN LEFT(ese.code, 1) = 'Z' THEN NULL ELSE SUBSTRING(ese.code, 2) END AS focus_other_ese_code
		,CASE WHEN (CASE WHEN du.ese_code = '0' THEN NULL ELSE SUBSTRING(du.ese_code, 2) END) != (CASE WHEN LEFT(ese.code, 1) = 'Z' THEN NULL ELSE SUBSTRING(ese.code, 2) END) THEN 'Y' ELSE NULL END AS other_ese_code_change
		,du.ell_code AS doe_ell_code
		,fieldoptioncode(s.custom_626) AS focus_ell_code
		,CASE WHEN du.ell_code != fieldoptioncode(s.custom_626) THEN 'Y' ELSE NULL END AS ell_code_change
		,du.lunch_status AS doe_lunch_status
		,fieldoptioncode(s.custom_71) AS focus_lunch_status
		,CASE WHEN du.lunch_status != fieldoptioncode(s.custom_71) THEN 'Y' ELSE NULL END AS lunch_status_change
		,CASE WHEN du.lunch_status != fieldoptioncode(s.custom_71) THEN s.custom_2012197376 ELSE NULL END AS lunch_status_change_date
		,du.met_grade_10_ela_reading_requirement AS doe_ela_met
		,CASE
			WHEN se.grade NOT IN ('10', '11', '12') then 'Z'
			WHEN fieldoptioncode(s.custom_200000244) IN ('Y', 'YC', 'YW') THEN 'Y'
			WHEN fieldoptioncode(s.custom_200000244) IN ('N', 'Z') THEN 'N'
			ELSE 'N'
		END AS focus_ela_met
		,CASE WHEN du.met_grade_10_ela_reading_requirement != (CASE WHEN se.grade NOT IN ('10', '11', '12') then 'Z' WHEN fieldoptioncode(s.custom_200000244) IN ('Y', 'YC', 'YW') THEN 'Y' WHEN fieldoptioncode(s.custom_200000244) IN ('N', 'Z') THEN 'N' ELSE 'N' END) THEN 'Y' ELSE NULL END AS ela_met_change
		,CASE WHEN du.met_grade_10_ela_reading_requirement != (CASE WHEN se.grade NOT IN ('10', '11', '12') then 'Z' WHEN fieldoptioncode(s.custom_200000244) IN ('Y', 'YC', 'YW') THEN 'Y' WHEN fieldoptioncode(s.custom_200000244) IN ('N', 'Z') THEN 'N' ELSE 'N' END) THEN CONCAT(SUBSTRING(s.custom_196, 3), SUBSTRING(s.custom_196, 1, 2), '01') ELSE NULL END AS ela_met_change_date
		,du.dropout_prevention_juvenile_justice_program_code AS doe_dop_code
		,dop.program AS focus_dop_code
		,CASE WHEN du.dropout_prevention_juvenile_justice_program_code != dop.program THEN 'Y' ELSE NULL END AS dop_code_change
		,CASE WHEN du.dropout_prevention_juvenile_justice_program_code != dop.program THEN COALESCE(dop.enroll_date, dop.drop_date) ELSE NULL END AS dop_code_change_date
		,du.withdrawn AS doe_withdrawn
		,du.withdrawn_from AS doe_withdrawn_from
		,CASE WHEN du.withdrawal_date = '0' THEN NULL ELSE du.withdrawal_date END AS doe_withdrawal_date
		,COALESCE(se.withdrawn, 'N') AS focus_withdrawn
		,CASE WHEN LPAD(du.school_of_enrollment, 4, '0') != se.school_num THEN 'Y' ELSE NULL END AS school_change
		,CASE WHEN LPAD(du.school_of_enrollment, 4, '0') != se.school_num THEN se.school ELSE NULL END AS school_current
		,CASE WHEN LPAD(du.school_of_enrollment, 4, '0') != se.school_num THEN se.start_date ELSE NULL END AS school_current_start_date
		,CASE WHEN du.withdrawn != COALESCE(se.withdrawn, 'N') THEN 'Y' ELSE NULL END AS withdrawn_change
		,CASE WHEN du.withdrawn != COALESCE(se.withdrawn, 'N') THEN se.drop_code ELSE NULL END AS withdrawn_change_code
		,CASE WHEN du.withdrawn != COALESCE(se.withdrawn, 'N') THEN 'NEED TYPE' ELSE NULL END AS withdrawn_change_from
		,CASE WHEN du.withdrawn != COALESCE(se.withdrawn, 'N') THEN se.end_date ELSE NULL END AS withdrawn_change_date
		,CASE WHEN du.year_entered_ninth_grade = '0' THEN NULL ELSE du.year_entered_ninth_grade END AS doe_ye9
		,CONCAT(SUBSTRING(fieldoptionlabel(s.custom_1429), 3, 2), SUBSTRING(fieldoptionlabel(s.custom_1429), 7, 2)) AS focus_ye9
		,CASE WHEN ((du.year_entered_ninth_grade != CONCAT(SUBSTRING(fieldoptionlabel(s.custom_1429), 3, 2), SUBSTRING(fieldoptionlabel(s.custom_1429), 7, 2))) AND LPAD(se.grade, 2, '0') IN ('09', '10', '11', '12')) THEN 'Y' ELSE NULL END AS ye9_change
	FROM
		student_data_updates_temp du
		LEFT JOIN students s ON (s.custom_200000224 = du.fleid)
		LEFT JOIN last_enrollment se ON (se.fleid = du.fleid)
		LEFT JOIN ese_codes ese ON (ese.fleid = du.fleid)
		LEFT JOIN dop_code dop ON (dop.fleid = du.fleid)
)

-- Output file
-- Has a column at the beginning to mark if a student has any eligible change so they can be filtered easily
SELECT
	CASE WHEN (bf.zoned_district_change = 'Y' OR bf.zoned_school_change = 'Y' OR bf.grade_level_change = 'Y' OR bf.primary_ese_code_change = 'Y' OR bf.other_ese_code_change = 'Y' OR bf.ell_code_change = 'Y' OR bf.lunch_status_change = 'Y' OR bf.ela_met_change = 'Y'
		OR bf.dop_code_change = 'Y' OR bf.withdrawn_change = 'Y' OR bf.schooL_change = 'Y' OR bf.ye9_change = 'Y') THEN 'Y' ELSE NULL END AS has_change
	,bf.record_id
	,bf.district_of_enrollment
	,bf.school_of_enrollment
	,bf.student_last_name
	,bf.student_first_name
	,bf.fleid
	,bf.date_of_birth
	,bf.sex
	,bf.race
	,bf.full_year_school
	,bf.full_year_district
	,bf.ext_med
	,bf.doe_zoned_district
	,bf.focus_zoned_district
	,bf.zoned_district_change
	,CASE WHEN bf.zoned_district_change = 'Y' THEN districtchange.change_date ELSE NULL END AS zoned_district_change_date
	,bf.doe_zoned_school
	,bf.focus_zoned_school
	,bf.zoned_school_change
	,CASE WHEN bf.zoned_school_change = 'Y' THEN schoolchange.change_date ELSE NULL END AS zoned_school_change_date
	,bf.doe_grade_level
	,bf.focus_grade_level
	,bf.grade_level_change
	,CASE WHEN bf.grade_level_change = 'Y' THEN gradechange.change_date ELSE NULL END AS grade_level_change_date
	,bf.doe_primary_ese_code
	,bf.focus_primary_ese_code
	,bf.primary_ese_code_change
	,CASE WHEN bf.primary_ese_code_change = 'Y' THEN pesechange.change_date ELSE NULL END AS primary_ese_code_change_date
	,bf.doe_other_ese_code
	,bf.focus_other_ese_code
	,bf.other_ese_code_change
	,CASE WHEN bf.other_ese_code_change = 'Y' THEN oesechange.change_date ELSE NULL END AS other_ese_code_change_date
	,bf.doe_ell_code
	,bf.focus_ell_code
	,bf.ell_code_change
	,CASE WHEN bf.ell_code_change = 'Y' THEN ellchange.change_date ELSE NULL END AS ell_code_change_date
	,bf.doe_lunch_status
	,bf.focus_lunch_status
	,bf.lunch_status_change
	,bf.lunch_status_change_date
	,bf.doe_ela_met
	,bf.focus_ela_met
	,bf.ela_met_change
	,bf.ela_met_change_date
	,bf.doe_dop_code
	,bf.focus_dop_code
	,bf.dop_code_change
	,bf.dop_code_change_date
	,bf.doe_withdrawn
	,bf.doe_withdrawn_from
	,bf.doe_withdrawal_date
	,bf.focus_withdrawn
	,bf.school_change
	,bf.school_current
	,bf.school_current_start_date
	,bf.withdrawn_change
	,bf.withdrawn_change_code
	,bf.withdrawn_change_from
	,bf.withdrawn_change_date
	,bf.doe_ye9
	,bf.focus_ye9
	,bf.ye9_change
FROM
	base_file bf
	LEFT JOIN zoned_district_change_date districtchange ON (districtchange.fleid = bf.fleid AND bf.zoned_district_change = 'Y')
	LEFT JOIN zoned_school_change_date schoolchange ON (schoolchange.fleid = bf.fleid AND bf.zoned_school_change = 'Y')
	LEFT JOIN grade_level_change_date gradechange ON (gradechange.fleid = bf.fleid AND bf.grade_level_change = 'Y')
	LEFT JOIN ese_prim_change_date pesechange ON (pesechange.fleid = bf.fleid AND bf.primary_ese_code_change = 'Y')
	LEFT JOIN ese_other_change_date oesechange ON (oesechange.fleid = bf.fleid AND bf.primary_ese_code_change = 'Y')
	LEFT JOIN ell_code_change_date ellchange ON (ellchange.fleid = bf.fleid AND bf.ell_code_change = 'Y')
GROUP BY 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63