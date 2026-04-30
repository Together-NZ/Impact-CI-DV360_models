{% macro dv360_standard(source_name, table_name,cm360_source_name,cm360_table_name) %}
WITH deduplicate_data AS (
    SELECT
        -- select dv360 standard data
        JSON_VALUE(data, "$.Advertiser Currency") AS advertiser_currency,
        JSON_VALUE(data, "$.CM360 Post-Click Revenue") AS cm360_post_click_revenue,
        JSON_VALUE(data, "$.CM360 Post-View Revenue") AS cm360_post_view_revenue,
        SAFE_CAST(JSON_VALUE(data, "$.Clicks") AS INT64) as clicks,
        SAFE_CAST(JSON_EXTRACT_SCALAR(data, "$['Complete Views (Video)']") AS INT64) AS video_completion,
        JSON_VALUE(data, "$.Creative") AS creative_name,
        JSON_VALUE(data, "$.Creative ID") AS creative_id,
        FORMAT_DATE('%Y-%m-%d', safe.PARSE_DATE('%Y/%m/%d', JSON_VALUE(data, "$.Date"))) AS date, -- Convert date format
        SAFE_CAST(JSON_EXTRACT_SCALAR(data, "$['First-Quartile Views (Video)']") AS INT64) AS video_25_completion,
        JSON_VALUE(data, "$.Floodlight Activity ID") AS floodlight_activity_id,
        JSON_VALUE(data, "$.Floodlight Activity Name") AS floodlight_activity_name,
        SAFE_CAST(JSON_VALUE(data, "$.Impressions") AS INT64) AS impressions,
        JSON_VALUE(data, "$.Insertion Order") AS campaign_name,
        JSON_VALUE(data, "$.Insertion Order ID") AS campaign_id,
        JSON_VALUE(data, "$.Insertion Order Status") AS campaign_status,
        JSON_VALUE(data, "$.Line Item") AS line_item,
        _sdc_extracted_at,
        JSON_VALUE(data, "$.Line Item ID") AS line_item_id,
        SAFE_CAST(JSON_EXTRACT_SCALAR(data, "$['Midpoint Views (Video)']") AS INT64) AS video_50_completion,
        JSON_VALUE(data, "$.Post-Click Conversions") AS post_click_conversions,
        JSON_VALUE(data, "$.Post-View Conversions") AS post_view_conversions,
        SAFE_CAST(JSON_EXTRACT_SCALAR(data, "$['Revenue (Adv Currency)']") AS FLOAT64)AS media_cost,
        SAFE_CAST(JSON_EXTRACT_SCALAR(data, "$['Third-Quartile Views (Video)']") AS INT64) AS video_75_completion,
        SAFE_CAST(JSON_VALUE(data, "$.Total Conversions") AS FLOAT64) AS conversions,
        ROW_NUMBER() OVER (
            PARTITION BY 
                FORMAT_DATE('%Y-%m-%d', safe.PARSE_DATE('%Y/%m/%d', JSON_VALUE(data, "$.Date"))), -- Use converted date
                JSON_VALUE(data, "$.Insertion Order ID"),
                JSON_VALUE(data, "$.Line Item ID"),
                JSON_VALUE(data, "$.Creative"),
                JSON_VALUE(data, "$.Floodlight Activity ID")
            ORDER BY 
                _sdc_extracted_at DESC -- Keep the record with the highest revenue
        ) AS row_num
    FROM
        {{ source(source_name, table_name) }}),
creative_name_update1 AS (
    SELECT creative_name,creative_id,ROW_NUMBER() OVER (
        PARTITION BY creative_id ORDER BY _sdc_extracted_at DESC
    ) AS row_num
    FROM deduplicate_data
),
creative_name_update_clean AS (
    SELECT creative_name,creative_id FROM creative_name_update1
    WHERE row_num = 1
),
campaign_name_update AS (
   SELECT campaign_name, campaign_id, ROW_NUMBER() OVER (
    PARTITION BY campaign_id ORDER BY _sdc_extracted_at DESC
   ) AS row_num
   FROM deduplicate_data
),
campaign_name_update_clean AS (
    SELECT campaign_name,campaign_id FROM campaign_name_update 
    WHERE row_num = 1
),


final_campaign_id AS (
SELECT *except(campaign_name) ,
    CASE 
        WHEN ARRAY_LENGTH(SPLIT(campaign_name, '_')) >= 3 AND SPLIT(campaign_name, '_')[OFFSET(3)] LIKE '%YT%' THEN 'Youtube Video'
        WHEN ARRAY_LENGTH(SPLIT(campaign_name,'_')) >= 3 THEN SPLIT(campaign_name, '_')[OFFSET(3)]
        ELSE 'Other'
    END AS media_format,

FROM deduplicate_data  
WHERE row_num = 1),
no_creative_changed AS (
SELECT campaign_id.*, campaign_name FROM 
final_campaign_id AS campaign_id LEFT JOIN 
campaign_name_update_clean ON campaign_id.campaign_id=campaign_name_update_clean.campaign_id
),
creative_name_update AS (
    SELECT reference.* EXCEPT(creative_name),creative_name_update_clean.creative_name FROM no_creative_changed AS reference LEFT JOIN creative_name_update_clean ON reference.creative_id=creative_name_update_clean.creative_id
),
cm360_campaign_creative AS (
  SELECT 'NZD' AS advertiser_currency,'0' AS cm360_post_click_revenue,'0' AS cm360_post_view_revenue,SUM(clicks) AS clicks,
  SUM(video_completion) AS video_completion,dv360_creative_id AS creative_id,SAFE_CAST(date AS STRING) AS date,SUM(video_25_completion) AS video_25_completion, ' ' AS floodlight_activity_id,'Unknown' AS floodlight_activity_name,sum(impressions) AS impressions,
  placement_id AS campaign_id,' ' as campaign_status,dv360_line_item AS line_item,SAFE_CAST(' ' AS TIMESTAMP) AS _sdc_extracted_at,SAFE_CAST(dv360_line_item_id AS STRING) 
  AS line_item_id,SUM(video_50_completion) AS video_50_completion, '0' as  post_click_conversions, '0' as post_view_conversions,SUM(dv360_cost) AS media_cost,SUM(video_75_completion) AS video_75_completion, SUM(total_conversions) AS total_conversions, 1 as row_num,
  ' ' as media_format,placement AS campaign_name,creative_name AS creative_name, SUM(video_views) AS video_views
   from {{ source(cm360_source_name, cm360_table_name) }}
   WHERE placement IN (
    SELECT DISTINCT campaign_name FROM creative_name_update
   )
   GROUP BY advertiser_currency,dv360_creative_id,date,floodlight_activity_id,floodlight_activity_name,placement_id,campaign_status,dv360_line_item,_sdc_extracted_at,dv360_line_item_id,media_format,placement,creative_name 
),
remove_360 AS (
    SELECT * FROM creative_name_update WHERE campaign_name NOT IN (
        SELECT DISTINCT campaign_name FROM cm360_campaign_creative
    )
),
joining AS (
    (SELECT * , video_25_completion AS video_views FROM remove_360) 
    UNION ALL
    (SELECT * FROM cm360_campaign_creative)
),
basic_result AS (
SELECT *  FROM joining)
SELECT *,    CASE 
        WHEN LOWER(campaign_name) LIKE '%nzme%' OR LOWER(creative_name) LIKE '%nzme%' THEN 'Nzme'
        WHEN LOWER(campaign_name) LIKE '%dg%' OR LOWER(campaign_name) LIKE '%demand gen%' OR (LOWER(campaign_name) LIKE '%demand%' 
        AND LOWER(campaign_name) LIKE '%gen%') THEN 'Demand Gen'
        WHEN LOWER(campaign_name) LIKE '%3now%' OR LOWER(campaign_name) LIKE '%three%'  OR LOWER(creative_name) LIKE '%3now%' OR LOWER(creative_name) LIKE '%three%' THEN 'Threenow'
        WHEN LOWER(campaign_name) LIKE '%youtube%' OR LOWER(creative_name) LIKE '%yt%' or lower(creative_name) LIKE '%yt%' or   LOWER(campaign_name) LIKE '%yt%' THEN 'Youtube'
        WHEN LOWER(campaign_name) LIKE '%TVNZ%' OR LOWER(creative_name) LIKE '%TVNZ%' or lower(creative_name) LIKE '%tvnz%' or   LOWER(campaign_name) LIKE '%tvnz%' THEN 'TVNZ'
        WHEN LOWER(campaign_name) LIKE '%metservice%' OR LOWER(creative_name) LIKE '%metservice%' THEN 'Metservice'
        WHEN LOWER(campaign_name) LIKE '%mediaworks%' OR LOWER(creative_name) LIKE '%mediaworks%' THEN 'MediaWorks'
        WHEN LOWER(campaign_name) LIKE '%business%' and LOWER(campaign_name) LIKE '%desk%' THEN 'Business Desk'
        WHEN LOWER(creative_name) LIKE '%business%' and LOWER(creative_name) LIKE '%desk%' THEN 'Business Desk'
        WHEN LOWER(campaign_name) LIKE '%acast%' OR LOWER(creative_name) LIKE '%acast%' THEN 'Acast'
        WHEN LOWER(campaign_name) LIKE '%perf%' AND LOWER(campaign_name) LIKE '%max%' OR LOWER(campaign_name) LIKE '%pmax%' THEN 'Performance Max'
        WHEN LOWER(campaign_name) LIKE '%stuff%' OR LOWER(creative_name) LIKE '%stuff%' THEN 'Stuff'
        ELSE 'Dv360'
    END AS publisher,
    REGEXP_EXTRACT(line_item, r'PLATFORM_([^_]+)') AS audience_name,
    CASE WHEN ARRAY_LENGTH(SPLIT(creative_name, '_')) >= 8 THEN SPLIT(creative_name, '_')[SAFE_OFFSET(7)] 
         ELSE 'Other' END AS creative_descr,
    CASE WHEN ARRAY_LENGTH(SPLIT(creative_name, '_')) >= 8 THEN SPLIT(creative_name, '_')[SAFE_OFFSET(5)] 
         
         ELSE 'Other' END AS ad_format_detail,
    CASE WHEN ARRAY_LENGTH(SPLIT(creative_name, '_')) >= 8 THEN SPLIT(creative_name, '_')[SAFE_OFFSET(6)] 
         
         ELSE 'Other' END AS ad_format,
    CASE WHEN ARRAY_LENGTH(SPLIT(campaign_name,'_')) <=1 THEN 'Other'
        ELSE SPLIT(campaign_name,'_')[SAFE_OFFSET(1)] END AS campaign_descr FROM basic_result

{% endmacro %}