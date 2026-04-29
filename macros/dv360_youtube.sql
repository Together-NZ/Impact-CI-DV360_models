{% macro dv360_youtube(source_name, table_name,dv360_standard_name,cm360_source_name,cm360_table_name) %}
-- This transformation rule joins conversion data for youtube camapign in campaign gandularity with rest of the metrics that 
-- are in creative granularity, it shares the same schema for both, and for conversion data, creative will be markes as 
-- 'YouTube conversion does not have creative breakdown', and the other metrics like media_cost,impression and clicks will be set to 0 for rows of data
-- that has conversion for youtube campaign, so when doing aggregration on clicks,impressions, and media_cost and conversions on campaign breakdown, the number
-- will not inflated.
WITH parsed_data AS (
    SELECT
        -- select the dv360 true view data
        JSON_VALUE(data, "$.Advertiser Currency") AS advertiser_currency,
        JSON_VALUE(data, "$.Clicks") AS clicks,
        JSON_EXTRACT_SCALAR(data, "$['Complete Views (Video)']") AS complete_views_video,
        FORMAT_DATE('%Y-%m-%d', safe.PARSE_DATE('%Y/%m/%d', JSON_VALUE(data, "$.Date"))) AS date, -- Convert date format
        JSON_EXTRACT_SCALAR(data, "$['First-Quartile Views (Video)']") AS first_quartile_views_video,
        JSON_VALUE(data, "$.Impressions") AS impressions,
        JSON_VALUE(data, "$.Insertion Order") AS campaign_name,
        JSON_VALUE(data, "$.Insertion Order ID") AS campaign_id,
        JSON_VALUE(data, "$.Insertion Order Status") AS campaign_status,
        JSON_VALUE(data, "$.Line Item") AS line_item,
        JSON_VALUE(data, "$.Line Item ID") AS line_item_id,
        JSON_EXTRACT_SCALAR(data, "$['Midpoint Views (Video)']") AS midpoint_views_video,
        JSON_EXTRACT_SCALAR(data, "$['Revenue (Adv Currency)']") AS media_cost,
        JSON_EXTRACT_SCALAR(data, "$['Third-Quartile Views (Video)']") AS third_quartile_views_video,
        JSON_VALUE(data, "$.YouTube Ad") AS creative_name,
        JSON_VALUE(data, "$.YouTube Ad ID") AS creative_id,
        JSON_VALUE(data, "$.YouTube Ad Group") AS youtube_ad_group,
        JSON_VALUE(data, "$.YouTube Ad Group ID") AS youtube_ad_group_id,
        _sdc_extracted_at,
        ROW_NUMBER() OVER (
            PARTITION BY 
                FORMAT_DATE('%Y-%m-%d', safe.PARSE_DATE('%Y/%m/%d', JSON_VALUE(data, "$.Date"))), -- Use converted date
                JSON_VALUE(data, "$.Insertion Order ID"),
                JSON_VALUE(data, "$.Line Item ID"),
                JSON_VALUE(data, "$.YouTube Ad ID"),
                JSON_VALUE(data, "$.YouTube Ad Group Ad ID")
                --safe_cast(TRUNC(SAFE_CAST(JSON_EXTRACT_SCALAR(data, "$['Revenue (Adv Currency)']") AS FLOAT64))as int64)
            ORDER BY 
                _sdc_extracted_at DESC -- Keep the record with the highest revenue
        ) AS row_num
    FROM
        {{ source(source_name, table_name) }}),
campaign_name_matching AS (
    SELECT DISTINCT campaign_name,campaign_id,creative_name FROM {{ref(dv360_standard_name)}}
),
campaign_name_update AS (
    SELECT s.* EXCEPT(campaign_name),naming_matching.campaign_name FROM parsed_data AS s
    LEFT JOIN campaign_name_matching AS naming_matching ON s.campaign_id=naming_matching.campaign_id
),
creative_name_matching AS (
    SELECT creative_name,creative_id, ROW_NUMBER() OVER (PARTITION BY creative_id ORDER BY _sdc_extracted_at DESC) AS row_num FROM parsed_data
),
creative_name_update_clean AS (
    SELECT creative_name,creative_id FROM creative_name_matching
    WHERE row_num = 1
),
joining AS (
    SELECT reference.* EXCEPT(creative_name),creative_name_update_clean.creative_name FROM parsed_data AS reference LEFT JOIN creative_name_update_clean ON reference.creative_id=creative_name_update_clean.creative_id   
),
cm360_campaign_creative AS (
                SELECT DISTINCT placement AS cm360_campaign_name,
                creative_name AS cm360_creative_name FROM {{ source(cm360_source_name, cm360_table_name) }}

),
creative_name_joining AS (
    SELECT source.*,cm360_creative_name
    FROM joining AS source LEFT JOIN cm360_campaign_creative AS reference ON
    source.campaign_name = reference.cm360_campaign_name
),
update_creative_name AS (
    SELECT * EXCEPT(creative_name),
    CASE WHEN cm360_creative_name IS NOT NULL
    THEN cm360_creative_name ELSE creative_name END AS creative_name
    FROM creative_name_joining
),
youtube_basic_metrics AS (

SELECT
    advertiser_currency,
    SAFE_CAST(clicks AS INT64) AS clicks,
    SAFE_CAST(complete_views_video AS INT64) AS video_completion,
    date,
    SAFE_CAST(first_quartile_views_video AS INT64) AS video_25_completion,
    safe_cast(impressions AS INT64) AS impressions,
    campaign_name,
    campaign_id,
    campaign_status,
    line_item,
    line_item_id,
    SAFE_CAST(midpoint_views_video AS INT64) AS video_50_completion,
    SAFE_CAST(media_cost AS FLOAT64) AS media_cost,
    SAFE_CAST(third_quartile_views_video AS INT64) AS video_75_completion,
    creative_name,
    youtube_ad_group,
    youtube_ad_group_id,
    --REGEXP_EXTRACT(line_item, r'PLATFORM_([^_]+)') AS audience_name,
    CASE WHEN LOWER(campaign_name) LIKE '%dg%' OR
    LOWER(campaign_name) LIKE '%demand gen%'  OR (LOWER(campaign_name) LIKE '%demand%' 
    AND LOWER(campaign_name) LIKE '%gen%') THEN 'Demand Gen'
    WHEN LOWER(campaign_name) LIKE '%youtube%' OR LOWER(creative_name) LIKE '%yt%' or lower(creative_name) LIKE '%yt%' or   LOWER(campaign_name) LIKE '%yt%' THEN 'YouTube'
    ELSE 'Dv360'
    END AS publisher,
    'Youtube Video' AS media_format,

    REGEXP_EXTRACT(line_item, r'PLATFORM_([^_]+)') AS audience_name,
    CASE  
         WHEN ARRAY_LENGTH(SPLIT(creative_name, '_')) >= 8 THEN SPLIT(creative_name, '_')[SAFE_OFFSET(7)] 
         ELSE 'Other' END AS creative_descr,
    CASE WHEN ARRAY_LENGTH(SPLIT(creative_name, '_')) >= 8 THEN SPLIT(creative_name, '_')[SAFE_OFFSET(5)] 
         
         ELSE 'Other' END AS ad_format_detail,
    CASE WHEN ARRAY_LENGTH(SPLIT(creative_name, '_')) >= 8 THEN SPLIT(creative_name, '_')[SAFE_OFFSET(6)] 
         
         ELSE 'Other' END AS ad_format,
    CASE WHEN ARRAY_LENGTH(SPLIT(campaign_name,'_')) <=1 THEN 'Other'
        ELSE SPLIT(campaign_name,'_')[SAFE_OFFSET(1)] END AS campaign_descr,
    null as conversions,
    CAST(null AS STRING) as floodlight_activity,
    CAST(null AS STRING) as floodlight_activity_id
   
FROM
    update_creative_name
WHERE
    row_num = 1 and campaign_name in (
        SELECT DISTINCT campaign_name FROM {{ref(dv360_standard_name)}}
    )),
youtube_conversion AS (
    SELECT * FROM {{ref(dv360_standard_name)}} WHERE campaign_name IN (
        SELECT DISTINCT campaign_name FROM campaign_name_update)
),
conversion_joining AS (
    SELECT advertiser_currency,
    0 as clicks,
    0 as video_completion,
    date,
    0 as video_25_completion,
    0 as impressions,
    campaign_name,
    campaign_id,
    campaign_status,
    line_item,
    line_item_id,
    0 as midpoint_views_video,
    0 as media_cost,
    0 as third_quartile_views_video,
    'YouTube conversion does not have creative breakdown' AS creative_name,
    '' AS youtube_ad_group,
    '' AS youtube_ad_group_id,
    publisher,
    media_format,
    audience_name,
    '' AS creative_descr,
    '' AS ad_format_detail,
    '' AS ad_format,
    campaign_descr,
    conversions as conversions,
    SAFE_CAST(floodlight_activity_name AS STRING) as floodlight_activity,
    SAFE_CAST(floodlight_activity_id AS STRING) AS floodlight_activity_id
    FROM youtube_conversion
)
SELECT * from youtube_basic_metrics UNION ALL
SELECT * FROM conversion_joining
{% endmacro %}