-- Purpose of query
/* 
The district administers a local Progress Monitoring Test for a variety of subjects 3-4 times a year
These test results are provided in longitudinal data - each student is a row and each question is a column
For consumption purposes in the data warehouse, it is much easier to have each question be a row (so a student would appear for 21 rows if there were 20 questions [each question and then overall score])
The only data provided is the student's ID, overall score, and then a 1 or 0 for if the question was right. Additional data about the student's course, the assessment itself, and standards data are added to provide a more comprehensive data set.

SIS = Student Information System
*/

-- This CTE compiles data about each student who took the assessment
-- There is hard-coded information that needs to be entered based on the assessment
-- coe (course of enrollment) and soe (school of enrollment) is to accurately capture where the student was and what course they were in at time of the assessment
-- BOTH coe and soe need to be 'Yes' to properly count the student
WITH general AS
(
	SELECT
		'2022' AS school_year
		,z.student_id
		,z.student_last
		,z.student_first
		,z.student_full
		,LPAD(z.school_id::text, 4, '0') AS school_id
		,z.school_name
		,z.course
		,z.teacher
		,z.assessment_grade_level
		,'Social Studies' AS subject
        ,'Civics' AS subject_category
		,'Civics CQA3' AS test_name
		,'20220311' AS test_date
		,'Quarter 3' AS time_period
		,z.start_date AS enrollment_start
	FROM
		(
			SELECT
				pm.student_id
				,s.last_name AS student_last
				,s.first_name AS student_first
				,INITCAP(CONCAT(s.last_name, ', ', s.first_name)) AS student_full
				,gl.title AS assessment_grade_level
				,sc.custom_327 AS school_id
				,sc.title AS school_name
				,c.title AS course
				,CASE
					WHEN (sch.end_date IS NULL AND sch.start_date <= '20220307') THEN 'Yes' 
					WHEN ((sch.end_date >= '20220307' AND sch.end_date <= '20220311') AND sch.start_date <= '20220307') THEN 'Yes'
					WHEN ((sch.start_date >= '20210811' AND sch.start_date <= '20220307') AND sch.end_date IS NOT NULL AND (ROW_NUMBER() OVER (PARTITION BY se.student_id ORDER BY sch.end_date DESC)) = 1) THEN 'Yes'
					ELSE 'No' 
				END AS coe
				,mp.short_name AS mp
				,cp.title AS period_teacher
				,INITCAP(CONCAT(u.last_name, ', ', u.first_name)) AS teacher
				,se.start_date
				,se.end_date
				,CASE
					WHEN (se.end_date IS NULL AND se.start_date <= '20220307') THEN 'Yes' 
					WHEN (se.end_date >= '20220307' AND se.end_date <= '20220311' AND se.start_date <= '20220307' AND (ROW_NUMBER() OVER (PARTITION BY se.student_id ORDER BY se.start_date DESC)) = 1) THEN 'Yes'
					WHEN (se.start_date >= '20210811' AND se.end_date IS NOT NULL AND (ROW_NUMBER() OVER (PARTITION BY se.student_id ORDER BY se.end_date DESC)) = 1) THEN 'Yes'
					ELSE 'No' 
				END AS soe
			FROM
				pm_civics_flip_temp pm
				INNER JOIN student_enrollment se ON (CAST(se.student_id AS varchar) = pm.student_id)
				INNER JOIN students s ON (CAST(s.student_id AS varchar) = pm.student_id AND s.student_id = se.student_id)
				INNER JOIN schools sc ON (sc.id = se.school_id)
				INNER JOIN school_gradelevels gl ON (gl.id = se.grade_id)
				INNER JOIN schedule sch ON (CAST(sch.student_id AS varchar) = pm.student_id AND sch.syear = se.syear AND sch.school_id = se.school_id)
				INNER JOIN course_periods cp ON (cp.course_period_id = sch.course_period_id AND cp.syear = se.syear)
				LEFT JOIN marking_periods mp ON (mp.marking_period_id = cp.marking_period_id)
				INNER JOIN school_periods sp ON (sp.period_id = cp.period_id)
				INNER JOIN courses c ON (c.course_id = cp.course_id AND c.syear = se.syear)
				INNER JOIN users u ON (u.staff_id = cp.teacher_id)
			WHERE
				se.syear = '2021'
				AND COALESCE(se.custom_9, 'N') = 'N' -- The enrollment at the school cannot be a secondary school enrollment
				AND (c.title iLIKE '%CIV%' OR c.title iLIKE '%HIST%') -- Only pulls students whose enrolled course matches the assessment
				AND (mp.short_name IS NULL OR mp.short_name = 'S1')
				AND sch.start_date <= '20220307' -- Enrollment in course  has to be on or before the final day of the assessment window
		) AS z
	WHERE
		z.soe = 'Yes'
		AND z.coe = 'Yes'
),

-- Pulls Question "Zero" which is the overall score of the assessment
overall AS
(
	SELECT
		z.*
		,z.question
		,z.score
		,z.answer
	FROM
		(
			SELECT
				g.*
				,'Overall Score' AS question
				,pm.test_score_ AS score
				,NULL AS answer
				,stan.standard
				,stan.description
				,stan.reporting_category
			FROM
				pm_civics_flip_temp pm
				INNER JOIN general g ON (g.student_id = pm.student_id)
				LEFT JOIN pm_civics_standards_temp stan ON (LPAD(stan.question::TEXT, 2, '0') = '00')
		) AS z
),


-- From here to the final UNION, these are all identical outside what question is being looked at
-- There is a join with pm_civics_standards_temp which brings in the answer key that identifies what standard and reporting category is attached to the question
-- This allows for analysis of percent correct by standard or category grouping
q1 AS
(
	SELECT
		z.*
		,z.question
		,z.score
		,z.answer
	FROM
		(
			SELECT
				g.*
				,'01' AS question
				,NULL AS score
				,pm._1 AS answer
				,stan.standard
				,stan.description
				,stan.reporting_category
			FROM
				pm_civics_flip_temp pm
				INNER JOIN general g ON (g.student_id = pm.student_id)
				INNER JOIN pm_civics_standards_temp stan ON (LPAD(stan.question::TEXT, 2, '0') = '01')
		) AS z
),

q2 AS
(
	SELECT
		z.*
		,z.question
		,z.score
		,z.answer
	FROM
		(
			SELECT
				g.*
				,'02' AS question
				,NULL AS score
				,_2 AS answer
				,stan.standard
				,stan.description
				,stan.reporting_category
			FROM
				pm_civics_flip_temp pm
				INNER JOIN general g ON (g.student_id = pm.student_id)
				INNER JOIN pm_civics_standards_temp stan ON (LPAD(stan.question::TEXT, 2, '0') = '02')
		) AS z
),

q3 AS
(
	SELECT
		z.*
		,z.question
		,z.score
		,z.answer
	FROM
		(
			SELECT
				g.*
				,'03' AS question
				,NULL AS score
				,_3 AS answer
				,stan.standard
				,stan.description
				,stan.reporting_category
			FROM
				pm_civics_flip_temp pm
				INNER JOIN general g ON (g.student_id = pm.student_id)
				INNER JOIN pm_civics_standards_temp stan ON (LPAD(stan.question::TEXT, 2, '0') = '03')
		) AS z
),

q4 AS
(
	SELECT
		z.*
		,z.question
		,z.score
		,z.answer
	FROM
		(
			SELECT
				g.*
				,'04' AS question
				,NULL AS score
				,_4 AS answer
				,stan.standard
				,stan.description
				,stan.reporting_category
			FROM
				pm_civics_flip_temp pm
				INNER JOIN general g ON (g.student_id = pm.student_id)
				INNER JOIN pm_civics_standards_temp stan ON (LPAD(stan.question::TEXT, 2, '0') = '04')
		) AS z
),

q5 AS
(
	SELECT
		z.*
		,z.question
		,z.score
		,z.answer
	FROM
		(
			SELECT
				g.*
				,'05' AS question
				,NULL AS score
				,_5 AS answer
				,stan.standard
				,stan.description
				,stan.reporting_category
			FROM
				pm_civics_flip_temp pm
				INNER JOIN general g ON (g.student_id = pm.student_id)
				INNER JOIN pm_civics_standards_temp stan ON (LPAD(stan.question::TEXT, 2, '0') = '05')
		) AS z
),

q6 AS
(
	SELECT
		z.*
		,z.question
		,z.score
		,z.answer
	FROM
		(
			SELECT
				g.*
				,'06' AS question
				,NULL AS score
				,_6 AS answer
				,stan.standard
				,stan.description
				,stan.reporting_category
			FROM
				pm_civics_flip_temp pm
				INNER JOIN general g ON (g.student_id = pm.student_id)
				INNER JOIN pm_civics_standards_temp stan ON (LPAD(stan.question::TEXT, 2, '0') = '06')
		) AS z
),

q7 AS
(
	SELECT
		z.*
		,z.question
		,z.score
		,z.answer
	FROM
		(
			SELECT
				g.*
				,'07' AS question
				,NULL AS score
				,_7 AS answer
				,stan.standard
				,stan.description
				,stan.reporting_category
			FROM
				pm_civics_flip_temp pm
				INNER JOIN general g ON (g.student_id = pm.student_id)
				INNER JOIN pm_civics_standards_temp stan ON (LPAD(stan.question::TEXT, 2, '0') = '07')
		) AS z
),

q8 AS
(
	SELECT
		z.*
		,z.question
		,z.score
		,z.answer
	FROM
		(
			SELECT
				g.*
				,'08' AS question
				,NULL AS score
				,_8 AS answer
				,stan.standard
				,stan.description
				,stan.reporting_category
			FROM
				pm_civics_flip_temp pm
				INNER JOIN general g ON (g.student_id = pm.student_id)
				INNER JOIN pm_civics_standards_temp stan ON (LPAD(stan.question::TEXT, 2, '0') = '08')
		) AS z
),

q9 AS
(
	SELECT
		z.*
		,z.question
		,z.score
		,z.answer
	FROM
		(
			SELECT
				g.*
				,'09' AS question
				,NULL AS score
				,_9 AS answer
				,stan.standard
				,stan.description
				,stan.reporting_category
			FROM
				pm_civics_flip_temp pm
				INNER JOIN general g ON (g.student_id = pm.student_id)
				INNER JOIN pm_civics_standards_temp stan ON (LPAD(stan.question::TEXT, 2, '0') = '09')
		) AS z
),

q10 AS
(
	SELECT
		z.*
		,z.question
		,z.score
		,z.answer
	FROM
		(
			SELECT
				g.*
				,'10' AS question
				,NULL AS score
				,_10 AS answer
				,stan.standard
				,stan.description
				,stan.reporting_category
			FROM
				pm_civics_flip_temp pm
				INNER JOIN general g ON (g.student_id = pm.student_id)
				INNER JOIN pm_civics_standards_temp stan ON (LPAD(stan.question::TEXT, 2, '0') = '10')
		) AS z
),

q11 AS
(
	SELECT
		z.*
		,z.question
		,z.score
		,z.answer
	FROM
		(
			SELECT
				g.*
				,'11' AS question
				,NULL AS score
				,_11 AS answer
				,stan.standard
				,stan.description
				,stan.reporting_category
			FROM
				pm_civics_flip_temp pm
				INNER JOIN general g ON (g.student_id = pm.student_id)
				INNER JOIN pm_civics_standards_temp stan ON (LPAD(stan.question::TEXT, 2, '0') = '11')
		) AS z
),

q12 AS
(
	SELECT
		z.*
		,z.question
		,z.score
		,z.answer
	FROM
		(
			SELECT
				g.*
				,'12' AS question
				,NULL AS score
				,_12 AS answer
				,stan.standard
				,stan.description
				,stan.reporting_category
			FROM
				pm_civics_flip_temp pm
				INNER JOIN general g ON (g.student_id = pm.student_id)
				INNER JOIN pm_civics_standards_temp stan ON (LPAD(stan.question::TEXT, 2, '0') = '12')
		) AS z
),

q13 AS
(
	SELECT
		z.*
		,z.question
		,z.score
		,z.answer
	FROM
		(
			SELECT
				g.*
				,'13' AS question
				,NULL AS score
				,_13 AS answer
				,stan.standard
				,stan.description
				,stan.reporting_category
			FROM
				pm_civics_flip_temp pm
				INNER JOIN general g ON (g.student_id = pm.student_id)
				INNER JOIN pm_civics_standards_temp stan ON (LPAD(stan.question::TEXT, 2, '0') = '13')
		) AS z
),

q14 AS
(
	SELECT
		z.*
		,z.question
		,z.score
		,z.answer
	FROM
		(
			SELECT
				g.*
				,'14' AS question
				,NULL AS score
				,_14 AS answer
				,stan.standard
				,stan.description
				,stan.reporting_category
			FROM
				pm_civics_flip_temp pm
				INNER JOIN general g ON (g.student_id = pm.student_id)
				INNER JOIN pm_civics_standards_temp stan ON (LPAD(stan.question::TEXT, 2, '0') = '14')
		) AS z
),

q15 AS
(
	SELECT
		z.*
		,z.question
		,z.score
		,z.answer
	FROM
		(
			SELECT
				g.*
				,'15' AS question
				,NULL AS score
				,_15 AS answer
				,stan.standard
				,stan.description
				,stan.reporting_category
			FROM
				pm_civics_flip_temp pm
				INNER JOIN general g ON (g.student_id = pm.student_id)
				INNER JOIN pm_civics_standards_temp stan ON (LPAD(stan.question::TEXT, 2, '0') = '15')
		) AS z
),

q16 AS
(
	SELECT
		z.*
		,z.question
		,z.score
		,z.answer
	FROM
		(
			SELECT
				g.*
				,'16' AS question
				,NULL AS score
				,_16 AS answer
				,stan.standard
				,stan.description
				,stan.reporting_category
			FROM
				pm_civics_flip_temp pm
				INNER JOIN general g ON (g.student_id = pm.student_id)
				INNER JOIN pm_civics_standards_temp stan ON (LPAD(stan.question::TEXT, 2, '0') = '16')
		) AS z
),

q17 AS
(
	SELECT
		z.*
		,z.question
		,z.score
		,z.answer
	FROM
		(
			SELECT
				g.*
				,'17' AS question
				,NULL AS score
				,_17 AS answer
				,stan.standard
				,stan.description
				,stan.reporting_category
			FROM
				pm_civics_flip_temp pm
				INNER JOIN general g ON (g.student_id = pm.student_id)
				INNER JOIN pm_civics_standards_temp stan ON (LPAD(stan.question::TEXT, 2, '0') = '17')
		) AS z
),

q18 AS
(
	SELECT
		z.*
		,z.question
		,z.score
		,z.answer
	FROM
		(
			SELECT
				g.*
				,'18' AS question
				,NULL AS score
				,_18 AS answer
				,stan.standard
				,stan.description
				,stan.reporting_category
			FROM
				pm_civics_flip_temp pm
				INNER JOIN general g ON (g.student_id = pm.student_id)
				INNER JOIN pm_civics_standards_temp stan ON (LPAD(stan.question::TEXT, 2, '0') = '18')
		) AS z
),

q19 AS
(
	SELECT
		z.*
		,z.question
		,z.score
		,z.answer
	FROM
		(
			SELECT
				g.*
				,'19' AS question
				,NULL AS score
				,_19 AS answer
				,stan.standard
				,stan.description
				,stan.reporting_category
			FROM
				pm_civics_flip_temp pm
				INNER JOIN general g ON (g.student_id = pm.student_id)
				INNER JOIN pm_civics_standards_temp stan ON (LPAD(stan.question::TEXT, 2, '0') = '19')
		) AS z
),

q20 AS
(
	SELECT
		z.*
		,z.question
		,z.score
		,z.answer
	FROM
		(
			SELECT
				g.*
				,'20' AS question
				,NULL AS score
				,_20 AS answer
				,stan.standard
				,stan.description
				,stan.reporting_category
			FROM
				pm_civics_flip_temp pm
				INNER JOIN general g ON (g.student_id = pm.student_id)
				INNER JOIN pm_civics_standards_temp stan ON (LPAD(stan.question::TEXT, 2, '0') = '20')
		) AS z
),

q21 AS
(
	SELECT
		z.*
		,z.question
		,z.score
		,z.answer
	FROM
		(
			SELECT
				g.*
				,'21' AS question
				,NULL AS score
				,_21 AS answer
				,stan.standard
				,stan.description
				,stan.reporting_category
			FROM
				pm_civics_flip_temp pm
				INNER JOIN general g ON (g.student_id = pm.student_id)
				INNER JOIN pm_civics_standards_temp stan ON (LPAD(stan.question::TEXT, 2, '0') = '21')
		) AS z
),

q22 AS
(
	SELECT
		z.*
		,z.question
		,z.score
		,z.answer
	FROM
		(
			SELECT
				g.*
				,'22' AS question
				,NULL AS score
				,_22 AS answer
				,stan.standard
				,stan.description
				,stan.reporting_category
			FROM
				pm_civics_flip_temp pm
				INNER JOIN general g ON (g.student_id = pm.student_id)
				INNER JOIN pm_civics_standards_temp stan ON (LPAD(stan.question::TEXT, 2, '0') = '22')
		) AS z
),

q23 AS
(
	SELECT
		z.*
		,z.question
		,z.score
		,z.answer
	FROM
		(
			SELECT
				g.*
				,'23' AS question
				,NULL AS score
				,_23 AS answer
				,stan.standard
				,stan.description
				,stan.reporting_category
			FROM
				pm_civics_flip_temp pm
				INNER JOIN general g ON (g.student_id = pm.student_id)
				INNER JOIN pm_civics_standards_temp stan ON (LPAD(stan.question::TEXT, 2, '0') = '23')
		) AS z
),

q24 AS
(
	SELECT
		z.*
		,z.question
		,z.score
		,z.answer
	FROM
		(
			SELECT
				g.*
				,'24' AS question
				,NULL AS score
				,_24 AS answer
				,stan.standard
				,stan.description
				,stan.reporting_category
			FROM
				pm_civics_flip_temp pm
				INNER JOIN general g ON (g.student_id = pm.student_id)
				INNER JOIN pm_civics_standards_temp stan ON (LPAD(stan.question::TEXT, 2, '0') = '24')
		) AS z
),

q25 AS
(
	SELECT
		z.*
		,z.question
		,z.score
		,z.answer
	FROM
		(
			SELECT
				g.*
				,'25' AS question
				,NULL AS score
				,_25 AS answer
				,stan.standard
				,stan.description
				,stan.reporting_category
			FROM
				pm_civics_flip_temp pm
				INNER JOIN general g ON (g.student_id = pm.student_id)
				INNER JOIN pm_civics_standards_temp stan ON (LPAD(stan.question::TEXT, 2, '0') = '25')
		) AS z
),

unions AS
(
		SELECT * FROM overall
	UNION ALL
		SELECT * FROM q1
	UNION ALL
		SELECT * FROM q2
	UNION ALL
		SELECT * FROM q3
	UNION ALL
		SELECT * FROM q4
	UNION ALL
		SELECT * FROM q5
	UNION ALL
		SELECT * FROM q6
	UNION ALL
		SELECT * FROM q7
	UNION ALL
		SELECT * FROM q8
	UNION ALL
		SELECT * FROM q9
	UNION ALL
		SELECT * FROM q10
	UNION ALL
		SELECT * FROM q11
	UNION ALL
		SELECT * FROM q12
	UNION ALL
		SELECT * FROM q13
	UNION ALL
		SELECT * FROM q14
	UNION ALL
		SELECT * FROM q15
	UNION ALL
		SELECT * FROM q16
	UNION ALL
		SELECT * FROM q17
	UNION ALL
		SELECT * FROM q18
	UNION ALL
		SELECT * FROM q19
	UNION ALL
		SELECT * FROM q20
	UNION ALL
		SELECT * FROM q21
	UNION ALL
		SELECT * FROM q22
	UNION ALL
		SELECT * FROM q23
	UNION ALL
		SELECT * FROM q24
	UNION ALL
		SELECT * FROM q25
)

-- Pull all from the UNION and then order by the student's ID for sorting
SELECT 
	u.*
FROM
	unions u
ORDER BY
	u.student_id
;