-- Purpose of query
/* 
This query was created as a result of there being issues with how courses were being weighted when it came time to assign GPA points after marking periods.
Prior to the 2021-2022 school year, all courses were weighted on a 7.0 scale. In the 2021-2022 school year, all courses changed to a 5.0 weighted scale.
What this query does is compile all the course information for a student for courses that are credit-bearing courses and compares the student's weighted GPA
from the program compared to what was appearing in the Student Information System. This would allow for identification of discrepencies for where students
were earning incorrect weighting on their courses, resulting in either a higher or lower GPA, Class Rank, or Percentile Rank.

5.0 Scale								7.0 Scale
Weight 5 AP IB AICE DE			=		Weight 7 AP IB AICE DE
Weight 4.5 Honors & Advanced	=		Weight 6 Honors & Advanced
Weight 4 On Level				=		Weight 5 On Level
Weight 4 On Level				=		Weight 4 Below Level

SIS = Student Information System
*/

-- Pulls all of a student's course history where the course affects GPA and credits attempted (srcg.credits) is not 0.
WITH course_history_initial AS
(
	SELECT
		srcg.student_id
		,srcg.syear
		,srcg.course_title
		,srcg.course_num
		,srcg.credits
		,srcg.credits_earned
		,srcg.grade_title
		,srcg.gpa_points AS unweighted_gpa_points
		,rcgs.title AS grade_scale
		-- Converts the 5.0 weight if the course is from the 2021-2022 school year to the 7.0 weight equivalent
		,CASE
			WHEN (srcg.syear >= '2021' AND rcgs.title = 'Weight 5 AP IB AICE DE') THEN '7'
			WHEN (srcg.syear >= '2021' AND rcgs.title = 'Weight 4.5 Honors & Advanced') THEN '6'
			WHEN (srcg.syear >= '2021' AND rcgs.title = 'Weight 4 On Level') THEN '5'
			ELSE SUBSTRING(rcgs.title, 8, 1)
		END AS old_scale_value
		,SUBSTRING(rcgs.title, 8, 1) AS current_scale_value
		,srcg.weighted_gpa_points AS current_weighted_gpa_points
		,srcg.gradelevel_title
	FROM
		student_report_card_grades srcg
		INNER JOIN report_card_grade_scales rcgs ON (rcgs.id = srcg.grade_scale_id)
	WHERE
		srcg.course_history = 'Y'
		AND srcg.affects_gpa = 'Y'
		AND srcg.credits <> 0
		
	ORDER BY
		srcg.syear DESC
),


-- From the last CTE, converts the weight level (4, 5, 6, 7) to the appropriate GPA points earned based on the level grade
-- If the student's grade was F, they earn no points. P and T are Out of District Transfers and do not provide GPA weighting. W is a withdrawn course.
course_history_old_weighted AS
(
	SELECT
		ch.*
		,CASE
			WHEN ch.old_scale_value = '7' AND ch.grade_title = 'A' THEN '7'
			WHEN ch.old_scale_value = '7' AND ch.grade_title = 'B' THEN '6'
			WHEN ch.old_scale_value = '7' AND ch.grade_title = 'C' THEN '5'
			WHEN ch.old_scale_value = '7' AND ch.grade_title = 'D' THEN '4'
			WHEN ch.old_scale_value = '6' AND ch.grade_title = 'A' THEN '6'
			WHEN ch.old_scale_value = '6' AND ch.grade_title = 'B' THEN '5'
			WHEN ch.old_scale_value = '6' AND ch.grade_title = 'C' THEN '4'
			WHEN ch.old_scale_value = '6' AND ch.grade_title = 'D' THEN '3'
			WHEN ch.old_scale_value = '5' AND ch.grade_title = 'A' THEN '5'
			WHEN ch.old_scale_value = '5' AND ch.grade_title = 'B' THEN '4'
			WHEN ch.old_scale_value = '5' AND ch.grade_title = 'C' THEN '3'
			WHEN ch.old_scale_value = '5' AND ch.grade_title = 'D' THEN '2'
			WHEN ch.old_scale_value = '4' AND ch.grade_title = 'A' THEN '4'
			WHEN ch.old_scale_value = '4' AND ch.grade_title = 'B' THEN '3'
			WHEN ch.old_scale_value = '4' AND ch.grade_title = 'C' THEN '2'
			WHEN ch.old_scale_value = '4' AND ch.grade_title = 'D' THEN '1'
			WHEN ch.grade_title IN ('F', 'P', 'T', 'W') THEN '0'
			ELSE '99'
		END AS old_weighted_gpa_points
	FROM
		course_history_initial ch
),

-- Constructing the student's current quality and GPA points in the SIS compared to what is generated from the prior CTE
course_history_final AS
(
	SELECT
		cha.student_id
		,cha.syear
		,cha.course_title
		,cha.credits
		,cha.credits_earned
		,cha.grade_title
		,cha.unweighted_gpa_points
		,ROUND((cha.credits_earned * cha.unweighted_gpa_points::decimal), 3) AS unweighted_quality_points
		,cha.grade_scale
		,cha.old_scale_value
		,cha.old_weighted_gpa_points
		,ROUND((cha.credits_earned * cha.old_weighted_gpa_points::decimal), 3) AS old_quality_points
		,cha.current_scale_value
		,cha.current_weighted_gpa_points
		,ROUND((cha.credits_earned * cha.current_weighted_gpa_points::decimal), 3) AS current_quality_points
	FROM
		course_history_old_weighted cha
),

-- Attaching students to their school and grade so then rankings and percentiles can be established based on the weighted GPA and those two factors
compiled_info AS
(
	SELECT
		sc.title AS school
		,gl.title AS grade_level
		,chf.*
	FROM
		students s
		INNER JOIN student_enrollment se ON (se.student_id = s.student_id)
		INNER JOIN schools sc ON (sc.id = se.school_id)
		INNER JOIN school_gradelevels gl ON (gl.id = se.grade_id)
		INNER JOIN course_history_final chf ON (chf.student_id = s.student_id)
		INNER JOIN marking_periods mp ON (mp.school_id = se.school_id AND mp.syear = se.syear AND mp.short_name = 'FY')
	WHERE
		se.syear = {SYEAR} -- SYEAR is a SIS variable that will only provide data based on the school year that the end user is running the report from
		{SCHOOL_SPECIFIC} AND sc.id = {SCHOOL_ID} -- SCHOOL_ID is a SIS variable that runs based on thes chool the end user is running from. This can be overriden by admin with higher permissions utilizing the SCHOOL_SPECIFIC variable where they can select "ALL" to see all sites they have access to
		AND COALESCE(se.end_date, mp.end_date) BETWEEN mp.end_date - interval '10 days' and mp.end_date
                AND (gl.title in ('{HS_GRADE_2}') or ('{HS_GRADE_2}' = 'ALL' and  gl.title in ('09','10','11','12'))) -- HS_GRADE_2 is a local variable where the end user can select if they want to see specific grades (9, 10, 11, 12) or all high school grades
		
),

-- Final composition of credits, quality points, and GPA points for students to prepare for rankings
gpas_final AS
(
	SELECT
		ci.student_id
		,ci.school
		,ci.grade_level
		,SUM(ci.credits) AS credits_attempted_total
		,SUM(ci.credits_earned) AS credits_earned_total
		,SUM(ci.unweighted_quality_points) AS unweighted_quality_points_total
		,SUM(ci.old_quality_points) AS old_quality_points_total
		,SUM(ci.current_quality_points) AS current_quality_points_total
		,ROUND((SUM(ci.unweighted_quality_points) / SUM(ci.credits)), 4) AS unweighted_GPA
		,ROUND((SUM(ci.old_quality_points) / SUM(ci.credits)), 4) AS old_weighted_GPA
		,ROUND((SUM(ci.current_quality_points) / SUM(ci.credits)), 4) AS current_weighted_GPA
	FROM
		compiled_info ci
	GROUP BY
		ci.student_id
		,ci.school
		,ci.grade_level
),

-- Rank each student based on their enrolled school and grade level for both what is provided in the SIS and from the program
rank_data AS
(
	SELECT
		gf.*
		,RANK() OVER (PARTITION BY gf.school, gf.grade_level ORDER BY gf.old_weighted_gpa DESC) AS old_gpa_rank
		,RANK() OVER (PARTITION BY gf.school, gf.grade_level ORDER BY gf.current_weighted_gpa DESC) AS current_gpa_rank
	FROM
		gpas_final gf
),

-- Compile number of students in each grade level at each school for denominator
student_count AS
(
	SELECT
		rd.school
		,rd.grade_level
		,COUNT(rd.student_id) AS students
	FROM
		rank_data rd
	GROUP BY
		rd.school	
		,rd.grade_level
)

-- Final output displayed to the end user
-- Displays student ID, school, and grade along with the credits, quality points, and GPA values based on the SIS and the program
-- Displays any changes in GPA, Class Rank, or Percentile to discover any mismatches to be fixed
SELECT
	rd.student_id AS "Student ID"
	,rd.school AS "School"
	,rd.grade_level AS "Grade Level"
	,rd.credits_attempted_total AS "Credits Attempted"
	,rd.credits_earned_total AS "Credits Earned"
	,rd.unweighted_quality_points_total AS "Unweighted Quality Points"
	,rd.old_quality_points_total AS "Adjusted Quality Points"
	,rd.current_quality_points_total AS "Current Quality Points"
	,rd.unweighted_gpa AS "Unweighted GPA"
	,rd.old_weighted_gpa AS "Adjusted Weighted GPA"
	,rd.current_weighted_gpa AS "Current Weighted GPA"
	,rd.old_gpa_rank AS "Adjusted Class Rank"
	,rd.current_gpa_rank AS "Current Class Rank"
	,ABS((rd.current_gpa_rank - rd.old_gpa_rank)) AS "Class Rank Change"
	,ROUND(((SUM(rd.old_gpa_rank) / SUM(sc.students)) * 100), 2) AS "Adjusted Percentile"
	,ROUND(((SUM(rd.current_gpa_rank) / SUM(sc.students)) * 100), 2) AS "Current Percentile"
FROM
	rank_data rd
	LEFT JOIN student_count sc ON (sc.school = rd.school AND sc.grade_level = rd.grade_level)
GROUP BY
	1,2,3,4,5,6,7,8,9,10,11,12,13