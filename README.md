# meloar-solr

## Search backend for the MeLOAR project

Indexes PDFs referenced in Open Access records from [LOAR](https://loar.kb.dk/) together with LOAR metadata and provides section-oriented search.


## Basic setup

Fetch `solrscripts` for easy setup of Solr:

```
git clone git@github.com:tokee/solrscripts.git
```

Install Solr
```
solrscripts/cloud_install.sh
```

Start Solr
```
solrscripts/cloud_start.sh
```

Upload the MeLOAR configuration and create a collection
```
solrscripts/cloud_sync.sh solr7 meloar-conf meloar
```

An empty collection should now be available at http://localhost:9595/solr/#/meloar/query


## Sample index

Index 2 fake records, each with 3 sections:
```
cloud/7.3.0/solr1/bin/post -p 9595 -c meloar samples/*
```

Inspect by performing a search in http://localhost:9595/solr/#/meloar/query


## Fetching of LOAR data

Fetch all from official LOAR OAI-PMH
```
REPOSITORY="https://loar.kb.dk/oai/request" METADATA_PREFIX="oai_dc" PROJECT="loar_kb" ./harvest_oai_pmh.sh
```
Results are stored in `loar_kb`. To update the harvest, re-run the command; it will continue from last time.


Fetch specific collection from stage LOAR OAI-PMH ("Arkæologiske undersøgelser"). Only available at the Royal Danish Library.
```
REPOSITORY="https://dspace-stage.statsbiblioteket.dk/oai/request" METADATA_PREFIX="oai_dc" PROJECT="loar_stage_kb" SET="com_1902_357" ./harvest_oai_pmh.sh
```


## Fetching of other sources

If the OAI-PMH source does not support the timestamp based `from`-parameter, only full harvests are possible:
```
USE_RESUMPTION="true" REPOSITORY="http://www.kulturarv.dk/ffrepox/OAIHandler" METADATA_PREFIX="ff" PROJECT="ff_slks" ./harvest_oai_pmh.sh
```
(this fetches 20K records in pages of 250 records)

Results are stored in a folder named from the `PROJECT`-parameter.

## Harvesting & indexing LOAR data

Fetch data
```
USE_RESUMPTION="true" REPOSITORY="https://dspace-stage.statsbiblioteket.dk/oai/request" METADATA_PREFIX="xoai" PROJECT="ff" SET="com_1902_357" ./harvest_oai_pmh.sh
```

Split into single records
```
PROJECT="ff" ./split_harvest.sh
```

Create basic SolrXMLDocuments for the records
```
PROJECT="ff" XSLT="$(pwd)/xoai2solr.xsl" SUB_SOURCE="records" SUB_DEST="solr_base" ./apply_xslt.sh
```

Fetch extra ff-metadata XML resources for the records and transform them
```
PROJECT="ff" SUB_SOURCE="solr_base" SUB_DEST="ff_raw_metadata" RESOURCE_FIELD="loar_resource" RESOURCE_EXT=".xml" ./fetch_resources.sh
PROJECT="ff" XSLT="$(pwd)/ff2solr.xsl" SUB_SOURCE="ff_raw_metadata" SUB_DEST="ff_enrich" ./apply_xslt.sh
```

Convert coordinates to OpenStreetMap/Solr/Google standard WGS 84
```
PROJECT="ff" SUB_SOURCE="ff_enrich" SUB_DEST="coordinates_converted" ./coordinate_convert.sh
```

Merge the extra ff-metadata into the basic SolrXMLDocuments
```
PROJECT="ff" SUB_SOURCE1="solr_base" SUB_SOURCE2="coordinates_converted" SUB_DEST="ff_merged" ./merge_solrdocs.sh
```

Fetch a JSON-breakdown of referenced PDFs, if available
```
PROJECT="ff" SUB_SOURCE="solr_base" SUB_DEST="pdf_json" RESOURCE_CHECK_FIELD="loar_resource" RESOURCE_CHECK_EXT=".xml" RESOURCE_FIELD="external_resource" RESOURCE_EXT="" URL_PREFIX="http://teg-desktop.sb.statsbiblioteket.dk:8080/loarindexer/services/pdfinfo?isAllowed=y&sequence=1&url=" ./fetch_resources.sh
```

Enrich the merged Solr Documents with the content from external PDFs, if available
```
PROJECT="ff" SUB_SOURCE="ff_merged" ./pdf_enrich.sh
```

Index the generated documents into Solr
```
cloud/7.3.0/solr1/bin/post -p 9595 -c meloar ff/pdf_enriched/*
```
