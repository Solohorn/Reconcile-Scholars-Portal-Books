Scholars Portal Books

Issue: There are many titles in Scholars Portal Books, and there are many Scholars Portal Books collections in the CZ. How can we determine whether we've activated all the titles we can access? How can we tell whether we've activated titles outside of our entitlements?

Solution: a Perl script to automate the reconciliation of entitlements and activations.

The script makes use of several sets of data:
1) Entitlement files from Scholars Portal Admintool
2) Batches of MARC records from Scholars Portal Admintool
3) URL exports from Alma, where the URL contains the domain "books.scholarsportal.info"

The script produces several outputs:
1) A report of titles activated in Alma that were found in Entitlements files
2) A report of titles activated in Alma but NOT found in Entitlements files
3) A report of titles NOT activated in Alma that were found in Entitlements files
4) A report of titles NOT activated in Alma that were found in Entitlements files with no associated MARC records
5) A batch or MARC records for titles NOT activated in Alma that were found in Entitlements files
6) A batch or MARC records for titles with URLs that did not adhere to an expected pattern for the platform

In theory, each URL we can access should be represented in an entitlement file.
In practice, there are a few issues that cause problems:
1) Sometimes the same entitlement is represented more than once using more than one URL (duplicate).
2) Sometimes an entitlement is legitimately represented using more than one URL (multi-volume set).
3) Sometimes a URL is not present in an entitlement file, yet we have access.

For missing titles, there may or may not be portfolios or bib records in the CZ. When there are, this script can help uncover entire collections that might be activated. In the absence of CZ portfolios for a given set of titles, or for those who chose not to activate portfolios from the CZ, getting the missing titles into Alma can be another challenge. Loading MARC records through an import profile can result in unnecessary duplication of bibliographic records. Attempts to load local portfolios can produce variable results when there are duplicate bibliographic records. A second script can add local portfolios to an electronic collection when they meet criteria that can be evaluated by an API call (for example, when they are present in an existing collection).

To do:
-- Generalize the script so that it can be used with many different institutions and vendors.
-- Alter the script to use a configuration file, so that institution and vendor-specific parameters can be set.
-- Review the URL path normalization routines, to see whether they can be simplified and configurable on a per-vendor basis.
-- Allow choice of MARC and MARCXML records.
-- Allow choice of UTF-8 or Ansel encoding for MARC records.
