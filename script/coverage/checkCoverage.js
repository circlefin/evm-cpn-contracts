/**
 * Copyright 2025 Circle Internet Group, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
const fs = require('fs');

// Dynamic header pattern - matches forge coverage table header regardless of spacing
const COVERAGE_TABLE_HEADER_PATTERN = /^\| File\s+\| % Lines\s+\| % Statements\s+\| % Branches\s+\| % Funcs\s+\|$/;
const COVERAGE_TABLE_TOTAL_ROW_NAME = 'Total';
const COVERAGE_TABLE_COLUMN_DELIM = '|';

// Parses the fraction portion for inputs like "78.96% (394/499)"
const COVERAGE_TABLE_COVERAGE_FRACTION_REGEXP = /\((\d+)\/(\d+)\)/;

const MIN_REQUIRED_LINE_COVERAGE_PERCENTAGE = 90;
const MIN_REQUIRED_STATEMENT_COVERAGE_PERCENTAGE = 90;
const MIN_REQUIRED_BRANCH_COVERAGE_PERCENTAGE = 90;
const MIN_REQUIRED_FUNCTION_COVERAGE_PERCENTAGE = 90;

const CoverageLevel = Object.freeze({
    DOES_NOT_MEET_MINIMUM: 0,
    MEETS_MINIMUM_WITH_SLACK: 1,
    MEETS_MINIMUM: 2,
});

const NUM_COLUMNS = 5; // File, % Lines, % Statements, % Branches, % Funcs

// If the total coverable units for a criteria falls below TOTAL_UNITS_SLACK_THRESHOLD for a file, reduce the minimum coverage percentage by COVERAGE_SLACK_PERCENTAGE. The
//  file will still be flagged as below threshold in the output, but won't cause minimum coverage check to fail. This leniency is to account for some files that have
//  unreachable lines of code, or lines that can't be detected by our coverage tool.
const TOTAL_UNITS_SLACK_THRESHOLD = 8;
const COVERAGE_SLACK_PERCENTAGE = 5;

const PASS_WITH_SLACK_WHITELIST_FILE = "script/coverage/passWithSlackWhitelist.txt"

function getNonWhitelistedPassWithSlackFiles(aboveThresholdWithSlackFileNames) {
    if (aboveThresholdWithSlackFileNames.length == 0) {
        return [];
    }
    let passWithSlackWhitelist = fs.readFileSync(PASS_WITH_SLACK_WHITELIST_FILE, "utf8").trim();
    if (passWithSlackWhitelist.length == 0) {
        return aboveThresholdWithSlackFileNames;
    }

    passWithSlackWhitelist = new Set(passWithSlackWhitelist.split("\n"));
    return aboveThresholdWithSlackFileNames.filter(fileName => !passWithSlackWhitelist.has(fileName));
}

function parseCoverageDetails(rawCoveragePercentText) {
    const match = COVERAGE_TABLE_COVERAGE_FRACTION_REGEXP.exec(rawCoveragePercentText);

    if (match) {
        return {
            coveredUnits: parseInt(match[1]),
            totalUnits: parseInt(match[2]),
        }
    }
    throw new Error(`Unparseable input: ${rawCoveragePercentText}`);
}

function parseCoverageTableRow(rawRowText) {
    let rowParts = rawRowText.split(COVERAGE_TABLE_COLUMN_DELIM);
    if (rowParts.length - 2 != NUM_COLUMNS) {
        return null
    }

    rowParts = rowParts.slice(1, -1);
    return {
        fileName: rowParts[0].trim(),
        lineCoverage: parseCoverageDetails(rowParts[1]),
        statementCoverage: parseCoverageDetails(rowParts[2]),
        branchCoverage: parseCoverageDetails(rowParts[3]),
        functionCoverage: parseCoverageDetails(rowParts[4]),
    }
}

function getCoverageLevel(coverageDetail, minCoveragePercent) {
    let coveragePercent = 100;
    if (coverageDetail.totalUnits > 0) {
        coveragePercent = (coverageDetail.coveredUnits / coverageDetail.totalUnits) * 100;
    }

    if (coveragePercent >= minCoveragePercent) {
        return CoverageLevel.MEETS_MINIMUM;
    } else if (coverageDetail.totalUnits <= TOTAL_UNITS_SLACK_THRESHOLD && (coveragePercent >= minCoveragePercent - COVERAGE_SLACK_PERCENTAGE)) {
        return CoverageLevel.MEETS_MINIMUM_WITH_SLACK;
    }
    return CoverageLevel.DOES_NOT_MEET_MINIMUM;
}

function getFileCoverageLevel(coverageRow) {
    return Math.min(
        getCoverageLevel(coverageRow.lineCoverage, MIN_REQUIRED_LINE_COVERAGE_PERCENTAGE),
        getCoverageLevel(coverageRow.statementCoverage, MIN_REQUIRED_STATEMENT_COVERAGE_PERCENTAGE),
        getCoverageLevel(coverageRow.branchCoverage, MIN_REQUIRED_BRANCH_COVERAGE_PERCENTAGE),
        getCoverageLevel(coverageRow.functionCoverage, MIN_REQUIRED_FUNCTION_COVERAGE_PERCENTAGE)
    );
}

function getFormattedCoverageTableRowsTest(coverageTableRows, tableHeader) {
    // Generate dynamic separator based on the actual header length
    const separator = '+' + '='.repeat(tableHeader.length - 2) + '+';
    return tableHeader + '\n'
        + separator + '\n'
        + coverageTableRows.join('\n') + '\n';
}

(async function main() {
    const coverateReportFileName = process.argv[2];
    const coverageReportRawText = fs.readFileSync(coverateReportFileName, "utf8");
    
    let coverageTableBodyRaw = "";
    let actualTableHeader = "";
    try {
        // Find the coverage table header dynamically
        const lines = coverageReportRawText.split('\n');
        let headerIndex = -1;
        
        for (let i = 0; i < lines.length; i++) {
            if (COVERAGE_TABLE_HEADER_PATTERN.test(lines[i])) {
                headerIndex = i;
                actualTableHeader = lines[i];
                break;
            }
        }
        
        if (headerIndex === -1) {
            throw new Error("Coverage table header not found");
        }
        
        // Extract everything after the header
        coverageTableBodyRaw = lines.slice(headerIndex + 1).join('\n');
    } catch (error) {
        console.error("Unexpected coverage report format");
        console.error(error);
        process.exit(1);
    }
    
    const belowThresholdFiles = [];
    const aboveThresholdWithSlackFileRows = [];
    const aboveThresholdWithSlackFileNames = [];
    const aboveThresholdFiles = [];
    let totalCoverageRow = "";
    // Skip the separator line (starts with +) and empty lines, then process data rows
    const allRows = coverageTableBodyRaw.split("\n");
    const coverageTableRows = allRows.filter((row, index) => {
        // Skip separator lines, empty lines, and the first line if it's a separator
        return row.trim() !== '' && !row.trim().startsWith('+') && !row.trim().startsWith('╰') && !row.trim().startsWith('╭');
    });
    
    for (const coverageTableRowRaw of coverageTableRows) {
        const coverageRow = parseCoverageTableRow(coverageTableRowRaw);
        if (!coverageRow) {
            continue;
        }
        if (coverageRow.fileName == COVERAGE_TABLE_TOTAL_ROW_NAME) {
            totalCoverageRow = coverageTableRowRaw;
            continue;
        }

        switch (getFileCoverageLevel(coverageRow)) {
            case CoverageLevel.MEETS_MINIMUM:
                aboveThresholdFiles.push(coverageTableRowRaw);
                break;
            case CoverageLevel.MEETS_MINIMUM_WITH_SLACK:
                aboveThresholdWithSlackFileRows.push(coverageTableRowRaw);
                aboveThresholdWithSlackFileNames.push(coverageRow.fileName);
                break;
            case CoverageLevel.DOES_NOT_MEET_MINIMUM:
                belowThresholdFiles.push(coverageTableRowRaw);
                break;
        }
    }
    const nonWhitelistedPassWithSlackFiles = getNonWhitelistedPassWithSlackFiles(aboveThresholdWithSlackFileNames);
    
    // Print coverage breakdown details
    console.log("Total coverage: ");
    console.log(getFormattedCoverageTableRowsTest([totalCoverageRow], actualTableHeader));

    if (belowThresholdFiles.length > 0) {
        console.log("Found files below coverage threshold: ");
        console.log(getFormattedCoverageTableRowsTest(belowThresholdFiles, actualTableHeader));
    } else {
        console.log("All source code files meet minimum coverage requirements.");
    }
    if (aboveThresholdWithSlackFileRows.length > 0) {
        console.log("Files above coverage threshold with slack (recommended, but not required to bump coverage for these files): ");
        console.log(getFormattedCoverageTableRowsTest(aboveThresholdWithSlackFileRows, actualTableHeader));

        if (nonWhitelistedPassWithSlackFiles.length > 0) {
            console.log(`Warning, some metrics from the below files only meet the coverage threshold with slack, but were expected to have all metrics pass without slack. Please thoroughly review the rows corresponding to these files above, and, if needed, add them to ${PASS_WITH_SLACK_WHITELIST_FILE}.`);
            console.log("\t-",nonWhitelistedPassWithSlackFiles.join("\n\t- "), "\n");
        }
    }
    if (aboveThresholdFiles.length > 0) {
        console.log("Files above coverage threshold: ");
        console.log(getFormattedCoverageTableRowsTest(aboveThresholdFiles, actualTableHeader));
    }

    // Fail if any files found below the minimum coverage threshold
    if (belowThresholdFiles.length > 0 || nonWhitelistedPassWithSlackFiles.length > 0) {
        // TODO: uncomment line once source code coverages have been bumped up
        // process.exit(2);
    }
})();
