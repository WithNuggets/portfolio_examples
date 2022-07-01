-- Purpose of query
/* 
These queries created as a result of changes in the GPA scale in the 2021-2022 school year.
After switching to a 5.0 scale, the decision was made for 10th to 12th graders to go back to the old 7.0 scale and to phase the 5.0 in.
These queries combines some DROP, CREATE, and UPDATE queries to achieve the end result.
There are two steps done:
1) Changing the necessary 5.0 scaled courses back to 7.0
2) Updating the weighted GPA points earned that properly reflect the 7.0 scale

5.0 Scale								7.0 Scale
Weight 5 AP IB AICE DE			=		Weight 7 AP IB AICE DE
Weight 4.5 Honors & Advanced	=		Weight 6 Honors & Advanced
Weight 4 On Level				=		Weight 5 On Level
Weight 4 On Level				=		Weight 4 Below Level

SIS = Student Information System
*/

-- Before any other queries run, DROP the course_history_update table if it exists for a clean slate
DROP TABLE IF EXISTS course_history_update;

-- Creating the base table that will be used for the UPDATE
-- Restricts only to courses that are in the student's course history, affects their GPA, and has credits attempted (srcg.credits <> 0)
CREATE TABLE course_history_update AS
(
	SELECT
		srcg.student_id
		,srcg.syear
		,srcg.school_id
		,srcg.course_title
		,srcg.course_num
		,srcg.credits
		,srcg.credits_earned
		,srcg.grade_title
		,rcgs.title AS grade_scale
		,srcg.grade_scale_id
		,CASE
			WHEN (srcg.syear >= '2021' AND srcg.course_num LIKE '79%') THEN 'Weight 4 Below Level'
			WHEN (srcg.syear >= '2021' AND rcgs.title = 'Weight 5 AP IB AICE DE') THEN 'Weight 7 AP DE IB'
			WHEN (srcg.syear >= '2021' AND rcgs.title = 'Weight 4.5 Honors & Advanced') THEN 'Weight 6 Honors & Advanced'
			WHEN (srcg.syear >= '2021' AND rcgs.title = 'Weight 4 On Level') THEN 'Weight 5 On Level'
			ELSE rcgs.title
		END AS seven_scale_value
		,srcg.custom_7 AS grade
		,mp.title AS mp
		,srcg.updated_at
	FROM
		student_report_card_grades srcg
		INNER JOIN report_card_grade_scales rcgs ON (rcgs.id = srcg.grade_scale_id)
		INNER JOIN marking_periods mp ON (mp.marking_period_id::varchar = srcg.marking_period_id)
	WHERE
		srcg.course_history = 'Y'
		AND srcg.affects_gpa = 'Y'
		AND srcg.credits <> 0
		AND srcg.syear = '2021'
	ORDER BY
		srcg.syear DESC
)
;

-- Based on the prior table created, update the report card grade scales table with the 7.0 scales
UPDATE 
	report_card_grade_scales rcgs
SET
	title = ch.seven_scale_value
FROM
	course_history_update ch
WHERE
	rcgs.id = ch.grade_scale_id
	AND ch.grade IN ('10', '11', '12')
;


-- Before any other queries run, DROP the course_history_weighted_gpa_points_update table if it exists for a clean slate
DROP TABLE IF EXISTS course_history_weighted_gpa_points_update;

-- Constructs the table that will be used to update the existing values in the course history of the student
-- Converts the weight level (4, 5, 6, 7) to the appropriate GPA points earned based on the level grade
-- If the student's grade was F, they earn no points. P and T are Out of District Transfers and do not provide GPA weighting. I is incomplete, W and WP are withdrawn courses.
CREATE TABLE course_history_weighted_gpa_points_update AS
(
	SELECT
		srcg.student_id
		,srcg.syear
		,srcg.school_id
		,srcg.marking_period_id
		,srcg.report_card_grade_id
		,srcg.course_title
		,srcg.course_num
		,srcg.credits
		,srcg.credits_earned
		,srcg.grade_title
		,rcgs.title AS grade_scale
		,srcg.weighted_gpa_points
		,CASE
			WHEN rcgs.title = 'Weight 7 AP DE IB' AND srcg.grade_title = 'A' THEN '7'
			WHEN rcgs.title = 'Weight 7 AP DE IB' AND srcg.grade_title = 'B' THEN '6'
			WHEN rcgs.title = 'Weight 7 AP DE IB' AND srcg.grade_title = 'C' THEN '5'
			WHEN rcgs.title = 'Weight 7 AP DE IB' AND srcg.grade_title = 'D' THEN '4'
			WHEN rcgs.title = 'Weight 7 AP DE IB' AND srcg.grade_title = 'F' THEN '0'
			WHEN rcgs.title = 'Weight 6 Honors & Advanced' AND srcg.grade_title = 'A' THEN '6'
			WHEN rcgs.title = 'Weight 6 Honors & Advanced' AND srcg.grade_title = 'B' THEN '5'
			WHEN rcgs.title = 'Weight 6 Honors & Advanced' AND srcg.grade_title = 'C' THEN '4'
			WHEN rcgs.title = 'Weight 6 Honors & Advanced' AND srcg.grade_title = 'D' THEN '3'
			WHEN rcgs.title = 'Weight 6 Honors & Advanced' AND srcg.grade_title = 'F' THEN '0'
			WHEN rcgs.title = 'Weight 5 On Level' AND srcg.grade_title = 'A' THEN '5'
			WHEN rcgs.title = 'Weight 5 On Level' AND srcg.grade_title = 'B' THEN '4'
			WHEN rcgs.title = 'Weight 5 On Level' AND srcg.grade_title = 'C' THEN '3'
			WHEN rcgs.title = 'Weight 5 On Level' AND srcg.grade_title = 'D' THEN '2'
			WHEN rcgs.title = 'Weight 5 On Level' AND srcg.grade_title = 'F' THEN '0'
			WHEN rcgs.title = 'Weight 4 Below Level' AND srcg.grade_title = 'A' THEN '4'
			WHEN rcgs.title = 'Weight 4 Below Level' AND srcg.grade_title = 'B' THEN '3'
			WHEN rcgs.title = 'Weight 4 Below Level' AND srcg.grade_title = 'C' THEN '2'
			WHEN rcgs.title = 'Weight 4 Below Level' AND srcg.grade_title = 'D' THEN '1'
			WHEN rcgs.title = 'Weight 4 Below Level' AND srcg.grade_title = 'F' THEN '0'
			WHEN srcg.grade_title IN ('F', 'P', 'T', 'I', 'W', 'WP') THEN '0'
			ELSE 99
		END AS updated_weighted_gpa_points
		,srcg.custom_7 AS grade
	FROM
		student_report_card_grades srcg
		INNER JOIN report_card_grade_scales rcgs ON (rcgs.id = srcg.grade_scale_id)
		INNER JOIN marking_periods mp ON (mp.marking_period_id::varchar = srcg.marking_period_id)
	WHERE
		srcg.course_history = 'Y'
		AND srcg.affects_gpa = 'Y'
		AND srcg.credits <> 0
		AND srcg.syear = '2021'
		AND srcg.custom_7 IN ('10', '11', '12')
	ORDER BY
		srcg.syear DESC
)
;

-- Based on the prior table created, update the weighted gpa points earned from the 5.0 scale to the 7.0 equivalent
UPDATE
	student_report_card_grades srcg
SET
	weighted_gpa_points = updated_weighted_gpa_points::numeric
FROM
	course_history_weighted_gpa_points_update up
WHERE
	srcg.student_id = up.student_id
	AND srcg.syear = up.syear
	AND srcg.course_num = up.course_num
	AND srcg.course_title = up.course_title
	AND srcg.custom_7 = up.grade
	AND srcg.marking_period_id = up.marking_period_id
	AND srcg.report_card_grade_id = up.report_card_grade_id
;