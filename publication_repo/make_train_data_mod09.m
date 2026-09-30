function [summaryTable, featureTable] = make_train_data_mod09(modisRoot, polygonsRoot, outputDir, geoMatPath)
%MAKE_TRAIN_DATA_MOD09 Inventory MOD09GA polygons and extract training samples.
%   [SUMMARYTABLE, FEATURETABLE] = MAKE_TRAIN_DATA_MOD09(MODISROOT,
%   POLYGONSROOT, OUTPUTDIR, GEOMATPATH) scans all shapefiles under
%   POLYGONSROOT whose names contain MOD09GA, matches each one to the
%   corresponding MOD09GA HDF tile in MODISROOT, and extracts features for
%   every polygon pixel.
%
%   GEOMATPATH is the optional path to geo_let_it_snow.mat on the 2400x2400
%   MODIS grid (elevation, slope, aspect).  Defaults to the canonical path
%   used by fill_spice_tile_dem_model.
%
%   The returned FEATURETABLE has one row per polygon-pixel sample with the
%   columns:
%     hs               - categorical polygon class from the folder name
%     polygon_id       - polygon feature index within the shapefile
%     modis_tile       - MOD09GA tile name without the trailing timestamp/hash
%     band_1..band_7   - reflectance from sur_refl_b01..sur_refl_b07
%     elevation        - terrain elevation (m) from geo_let_it_snow.mat
%     slope            - terrain slope (deg) from geo_let_it_snow.mat
%     aspect           - terrain aspect (deg) from geo_let_it_snow.mat
%     time_sin         - sin(2*pi*DOY/365)  cyclic day-of-year encoding
%     time_cos         - cos(2*pi*DOY/365)  cyclic day-of-year encoding
%     ndsi             - (band_4 - band_6) / (band_4 + band_6)
%     ratio_b1_b6      - band_1 / band_6  (ice/snow vs bare ground)
%     ratio_b1_b2      - band_1 / band_2  (dust/dirtiness factor)
%     ratio_b2_b6      - band_2 / band_6  (snow vs glacier ice crystal structure)
%     x_sinu           - pixel centre X in MODIS sinusoidal projection (m)
%     y_sinu           - pixel centre Y in MODIS sinusoidal projection (m)
%
%   Output files (saved to OUTPUTDIR, no CSVs):
%     mod09ga_features_<tag>_<yyyymmdd>.mat  — featureTable
%     mod09ga_summary_<yyyymmdd>.mat          — summaryTable
%
%   Feature tag abbreviations used in the filename:
%     b1_7    = bands 1-7 (or b<n> for a subset)
%     dem     = elevation, slope, aspect
%     time    = time_sin, time_cos
%     ndsi    = ndsi
%     ratios  = ratio_b1_b6, ratio_b1_b2, ratio_b2_b6
%     xy      = x_sinu, y_sinu

    if nargin < 1 || isempty(modisRoot)
        modisRoot = '/data/MOD09GA';
    end
    if nargin < 2 || isempty(polygonsRoot)
        polygonsRoot = '/data/joklar/verkefni/2026 - Spectral Glaciers/data/classified_polygons-eva';
    end
    if nargin < 3 || isempty(outputDir)
        outputDir = fullfile(fileparts(mfilename('fullpath')), 'train_tables_and_models');
    end
    if nargin < 4 || isempty(geoMatPath)
        geoMatPath = localDefaultGeoMatPath();
    end

    localLog('Starting MOD09GA polygon classification workflow.');
    localLog(sprintf('MODIS root: %s', modisRoot));
    localLog(sprintf('Polygon root: %s', polygonsRoot));
    localLog(sprintf('Output dir: %s', outputDir));
    localLog(sprintf('Geo MAT: %s', geoMatPath));

    geoData = localLoadGeoData(geoMatPath);
    localLog(sprintf('Geo data loaded — elevation ok: %d, slope ok: %d, aspect ok: %d', ...
        any(isfinite(geoData.elevation(:))), ...
        any(isfinite(geoData.slope(:))), ...
        any(isfinite(geoData.aspect(:)))));

    shapefiles = localFindMod09gaShapefiles(polygonsRoot);
    localLog(sprintf('Discovered %d shapefile(s) matching *MOD09GA*.shp.', numel(shapefiles)));
    summaryTable = localBuildSummaryTable(shapefiles, modisRoot);
    if ~isempty(summaryTable)
        localLog(sprintf('Summary ready: %d matched, %d unmatched.', sum(summaryTable.has_matching_modis), sum(~summaryTable.has_matching_modis)));
    end

    if isempty(shapefiles)
        localLog('No MOD09GA shapefiles found. Returning empty feature table.');
        featureTable = table();
        return;
    end

    bandCache = containers.Map('KeyType', 'char', 'ValueType', 'any');
    extractedTables = cell(numel(shapefiles), 1);
    for k = 1:numel(shapefiles)
        localLog(sprintf('Processing shapefile %d/%d: %s', k, numel(shapefiles), shapefiles{k}));
        [extractedTables{k}, bandCache] = localExtractShapefileSamples(shapefiles{k}, modisRoot, bandCache, geoData);
    end

    extractedTables = extractedTables(~cellfun(@isempty, extractedTables));
    if isempty(extractedTables)
        featureTable = table();
        localLog('No pixel samples were extracted from any polygon.');
    else
        featureTable = vertcat(extractedTables{:});
        featureTable.hs = categorical(featureTable.hs);
        localLog(sprintf('Extracted %d pixel samples total.', height(featureTable)));
    end

    if ~isempty(outputDir)
        if ~exist(outputDir, 'dir')
            mkdir(outputDir);
            localLog(sprintf('Created output directory: %s', outputDir));
        end
        datestamp = char(datetime('now', 'Format', 'yyyyMMdd'));
        featureTag = localFeatureTag(featureTable.Properties.VariableNames);
        featureMatPath = fullfile(outputDir, sprintf('mod09ga_features_%s_%s.mat', featureTag, datestamp));
        save(featureMatPath, 'featureTable', '-v7.3');
        localLog(sprintf('Wrote feature table : %s', featureMatPath));
    end

    localLog('Workflow completed.');
end

function shapefiles = localFindMod09gaShapefiles(polygonsRoot)
    searchResult = dir(fullfile(polygonsRoot, '**', '*MOD09GA*.shp'));
    shapefiles = fullfile({searchResult.folder}, {searchResult.name});
end

function summaryTable = localBuildSummaryTable(shapefiles, modisRoot)
    nFiles = numel(shapefiles);
    folderName = strings(nFiles, 1);
    shapefileName = strings(nFiles, 1);
    modisTileName = strings(nFiles, 1);
    modisFile = strings(nFiles, 1);
    hasMatch = false(nFiles, 1);
    featureCount = zeros(nFiles, 1);
    polygonClass = strings(nFiles, 1);
    tileToken = strings(nFiles, 1);

    for k = 1:nFiles
        shapefilePath = shapefiles{k};
        [currentFolder, currentName] = fileparts(shapefilePath);
        [~, folderLabel] = fileparts(currentFolder);

        shapefileName(k) = string(currentName);
        folderName(k) = string(folderLabel);
        polygonClass(k) = string(extractBefore(currentName, '_MOD09GA'));
        featureInfo = shaperead(shapefilePath, 'UseGeoCoords', false);
        featureCount(k) = numel(featureInfo);

        tileToken(k) = localExtractTileToken(currentName);
        match = localFindModisFile(modisRoot, tileToken(k));
        if ~isempty(match)
            hasMatch(k) = true;
            modisFile(k) = string(match);
            modisTileName(k) = string(localTileNameFromModisFile(match));
        else
            localLog(sprintf('No matching MODIS tile found for shapefile: %s', shapefilePath));
        end
    end

    summaryTable = table(folderName, polygonClass, shapefileName, tileToken, featureCount, hasMatch, modisTileName, modisFile, ...
        'VariableNames', {'folder', 'hs', 'shapefile', 'tile_token', 'feature_count', 'has_matching_modis', 'modis_tile', 'modis_file'});
    summaryTable.hs = categorical(summaryTable.hs);
end

function [extractedTable, bandCache] = localExtractShapefileSamples(shapefilePath, modisRoot, bandCache, geoData)
    [shapefileFolder, shapefileName] = fileparts(shapefilePath);
    [~, folderLabel] = fileparts(shapefileFolder);
    hsLabel = string(extractBefore(shapefileName, '_MOD09GA'));
    tileToken = localExtractTileToken(shapefileName);
    modisFile = localFindModisFile(modisRoot, tileToken);

    if isempty(modisFile)
        localLog(sprintf('Skipping shapefile with no MODIS match: %s', shapefilePath));
        extractedTable = table();
        return;
    end

    localLog(sprintf('Matched MODIS file: %s', modisFile));

    [bandData, bandCache] = localLoadMod09gaBands(modisFile, bandCache);
    if isempty(bandData)
        localLog(sprintf('Failed to load MODIS bands for: %s', modisFile));
        extractedTable = table();
        return;
    end

    features = shaperead(shapefilePath, 'UseGeoCoords', false);
    if isempty(features)
        localLog(sprintf('No polygon features found in shapefile: %s', shapefilePath));
        extractedTable = table();
        return;
    end

    localLog(sprintf('Extracting %d polygon feature(s) from: %s', numel(features), shapefilePath));

    doy = localParseDoyFromTileToken(tileToken);
    allTables = cell(numel(features), 1);
    for p = 1:numel(features)
        allTables{p} = localSamplePolygonFeature(features(p), bandData.spatialRef, hsLabel, folderLabel, tileToken, p, bandData, geoData, doy);
    end

    allTables = allTables(~cellfun(@isempty, allTables));
    if isempty(allTables)
        extractedTable = table();
        localLog(sprintf('No valid pixel samples extracted from: %s', shapefilePath));
    else
        extractedTable = vertcat(allTables{:});
        extractedTable.hs = categorical(extractedTable.hs);
        localLog(sprintf('Extracted %d sample rows from: %s', height(extractedTable), shapefilePath));
    end
end

function sampleTable = localSamplePolygonFeature(feature, spatialRef, hsLabel, folderLabel, tileToken, polygonId, bandData, geoData, doy)
    [rowGrid, colGrid] = localPolygonPixels(feature.X, feature.Y, spatialRef);
    if isempty(rowGrid)
        sampleTable = table();
        return;
    end

    pixelCount = numel(rowGrid);
    hs         = repmat(string(hsLabel),     pixelCount, 1);
    folder     = repmat(string(folderLabel), pixelCount, 1);
    modisTile  = repmat(string(tileToken),   pixelCount, 1);
    polygon_id = repmat(polygonId,           pixelCount, 1);

    indices = sub2ind(size(bandData.band1), rowGrid, colGrid);
    band_1 = bandData.band1(indices);
    band_2 = bandData.band2(indices);
    band_3 = bandData.band3(indices);
    band_4 = bandData.band4(indices);
    band_5 = bandData.band5(indices);
    band_6 = bandData.band6(indices);
    band_7 = bandData.band7(indices);

    % Terrain features from DEM
    elevation = geoData.elevation(indices);
    slope     = geoData.slope(indices);
    aspect    = geoData.aspect(indices);

    % Cyclic time-of-year encoding (avoids discontinuity between DOY 365 and 1)
    time_sin = repmat(sin(2 * pi * doy / 365), pixelCount, 1);
    time_cos = repmat(cos(2 * pi * doy / 365), pixelCount, 1);

    % NDSI: (Green - SWIR) / (Green + SWIR)  [MOD09GA: band 4 = green, band 6 = SWIR]
    ndsi = (band_4 - band_6) ./ (band_4 + band_6);
    ndsi(~isfinite(ndsi)) = NaN;

    % Band ratios
    ratio_b1_b6 = band_1 ./ band_6;   % ice/snow vs bare ground boundary
    ratio_b1_b2 = band_1 ./ band_2;   % dust/dirtiness factor
    ratio_b2_b6 = band_2 ./ band_6;   % snow vs glacier ice crystal structure
    ratio_b1_b6(~isfinite(ratio_b1_b6)) = NaN;
    ratio_b1_b2(~isfinite(ratio_b1_b2)) = NaN;
    ratio_b2_b6(~isfinite(ratio_b2_b6)) = NaN;

    % MODIS sinusoidal pixel-centre coordinates.
    % intrinsicToWorld convention: intrinsicX = column, intrinsicY = row.
    % These give the easting (X) and northing (Y) in the MODIS sinusoidal
    % projection (metres), letting the model learn systematic east-west and
    % elevation-band patterns that are not captured by the spectral features.
    [x_sinu, y_sinu] = intrinsicToWorld(spatialRef, double(colGrid), double(rowGrid));
    x_sinu = x_sinu(:);
    y_sinu = y_sinu(:);

    sampleTable = table(hs, folder, polygon_id, modisTile, ...
        band_1, band_2, band_3, band_4, band_5, band_6, band_7, ...
        elevation, slope, aspect, time_sin, time_cos, ...
        ndsi, ratio_b1_b6, ratio_b1_b2, ratio_b2_b6, ...
        x_sinu, y_sinu, ...
        'VariableNames', {'hs', 'folder', 'polygon_id', 'modis_tile', ...
        'band_1', 'band_2', 'band_3', 'band_4', 'band_5', 'band_6', 'band_7', ...
        'elevation', 'slope', 'aspect', 'time_sin', 'time_cos', ...
        'ndsi', 'ratio_b1_b6', 'ratio_b1_b2', 'ratio_b2_b6', ...
        'x_sinu', 'y_sinu'});
end

function [rowGrid, colGrid] = localPolygonPixels(x, y, spatialRef)
    valid = ~isnan(x) & ~isnan(y);
    x = x(valid);
    y = y(valid);

    if numel(x) < 3
        rowGrid = [];
        colGrid = [];
        return;
    end

    partBreaks = find(isnan(x) | isnan(y));
    starts = [1, partBreaks(:)' + 1];
    stops = [partBreaks(:)' - 1, numel(x)];

    mask = false(spatialRef.RasterSize(1), spatialRef.RasterSize(2));
    for i = 1:numel(starts)
        if stops(i) - starts(i) + 1 < 3
            continue;
        end
        xi = x(starts(i):stops(i));
        yi = y(starts(i):stops(i));
        [xIntrinsic, yIntrinsic] = worldToIntrinsic(spatialRef, xi, yi);
        mask = mask | poly2mask(xIntrinsic, yIntrinsic, spatialRef.RasterSize(1), spatialRef.RasterSize(2));
    end

    [rowGrid, colGrid] = find(mask);
end

function [bandData, bandCache] = localLoadMod09gaBands(modisFile, bandCache)
    cacheKey = char(modisFile);
    if isKey(bandCache, cacheKey)
        bandData = bandCache(cacheKey);
        localLog(sprintf('Using cached MODIS bands for: %s', modisFile));
        return;
    end

    tileToken = localTileNameFromModisFile(modisFile);
    rasterSize = [2400, 2400];
    pixelSize = 463.312716527778;
    [xWorldLimits, yWorldLimits] = localModisTileWorldLimits(tileToken, rasterSize, pixelSize);
    spatialRef = imref2d(rasterSize, xWorldLimits, yWorldLimits);

    tempDir = fullfile(tempdir, ['mod09ga_', char(java.util.UUID.randomUUID)]);
    mkdir(tempDir);
    cleanupHandle = onCleanup(@() rmdir(tempDir, 's'));

    bandData = struct('band1', [], 'band2', [], 'band3', [], 'band4', [], 'band5', [], 'band6', [], 'band7', [], 'spatialRef', spatialRef);
    for b = 1:7
        bandName = sprintf('sur_refl_b%02d_1', b);
        tempTif = fullfile(tempDir, sprintf('band_%02d.tif', b));
        source = sprintf('HDF4_EOS:EOS_GRID:"%s":MODIS_Grid_500m_2D:%s', modisFile, bandName);
        command = sprintf('gdal_translate -q -of GTiff ''%s'' ''%s''', source, tempTif);
        status = system(command);
        if status ~= 0 || ~exist(tempTif, 'file')
            bandData = [];
            clear cleanupHandle;
            localLog(sprintf('gdal_translate failed for band %02d in file: %s', b, modisFile));
            return;
        end

        [bandArray, readRef] = readgeoraster(tempTif);
        if b == 1
            bandData.spatialRef = readRef;
        end
        bandArray = double(bandArray);
        bandArray(bandArray <= -28672) = NaN;
        bandData.(sprintf('band%d', b)) = bandArray;
    end

    bandCache(cacheKey) = bandData;
    localLog(sprintf('Loaded and cached MODIS bands for: %s', modisFile));
end

function [xWorldLimits, yWorldLimits] = localModisTileWorldLimits(tileToken, rasterSize, pixelSize)
    token = regexp(char(tileToken), 'MOD09GA\.A\d{7}\.h(\d{2})v(\d{2})\.\d{3}', 'tokens', 'once');
    if isempty(token)
        error('Could not parse MODIS tile token from "%s".', tileToken);
    end

    h = str2double(token{1});
    v = str2double(token{2});
    tileWidth = rasterSize(2) * pixelSize;
    tileHeight = rasterSize(1) * pixelSize;
    xMin = -20015109.354 + h * tileWidth;
    xMax = xMin + tileWidth;
    yMax = 10007554.677 - v * tileHeight;
    yMin = yMax - tileHeight;
    xWorldLimits = [xMin, xMax];
    yWorldLimits = [yMin, yMax];
end

function tileToken = localExtractTileToken(shapefileName)
    token = regexp(char(shapefileName), 'MOD09GA\.A\d{7}\.h\d{2}v\d{2}\.\d{3}', 'match', 'once');
    tileToken = string(token);
end

function modisFile = localFindModisFile(modisRoot, tileToken)
    modisFile = '';
    if strlength(tileToken) == 0
        return;
    end

    fileList = dir(fullfile(modisRoot, [char(tileToken), '*.hdf']));
    if isempty(fileList)
        return;
    end

    modisFile = fullfile(fileList(1).folder, fileList(1).name);
end

function tileName = localTileNameFromModisFile(modisFile)
    [~, baseName, ~] = fileparts(modisFile);
    token = regexp(baseName, '^(MOD09GA\.A\d{7}\.h\d{2}v\d{2}\.\d{3})', 'tokens', 'once');
    if isempty(token)
        tileName = string(baseName);
    else
        tileName = string(token{1});
    end
end

function localLog(message)
    fprintf('[%s] %s\n', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')), message);
end

function tag = localFeatureTag(varNames)
%LOCALFEATURETAG  Build a short descriptive tag from table column names.
%   Groups are detected in order and joined with underscores:
%     b1_7   = all bands 1-7 present  (b<list> if a subset, e.g. b136)
%     dem    = elevation + slope + aspect
%     time   = time_sin / time_cos
%     ndsi   = ndsi
%     ratios = any ratio_* columns
%     xy     = x_sinu + y_sinu
    parts = {};

    % --- bands ---
    bandNums = [];
    for i = 1:numel(varNames)
        m = regexp(char(varNames{i}), '^band_(\d+)$', 'tokens', 'once');
        if ~isempty(m)
            bandNums(end+1) = str2double(m{1}); %#ok<AGROW>
        end
    end
    if ~isempty(bandNums)
        bandNums = sort(unique(bandNums));
        if isequal(bandNums(:)', 1:7)
            parts{end+1} = 'b1_7';
        else
            parts{end+1} = ['b', strjoin(string(bandNums), '')];
        end
    end

    % --- terrain ---
    demPresent = sum(ismember({'elevation','slope','aspect'}, varNames));
    if demPresent == 3
        parts{end+1} = 'dem';
    elseif demPresent > 0
        sub = intersect({'elevation','slope','aspect'}, varNames);
        abbr = cellfun(@(s) s(1), sub, 'UniformOutput', false);
        parts{end+1} = strjoin(abbr, '');
    end

    % --- cyclic time ---
    if any(ismember({'time_sin','time_cos'}, varNames))
        parts{end+1} = 'time';
    end

    % --- NDSI ---
    if any(strcmp('ndsi', varNames))
        parts{end+1} = 'ndsi';
    end

    % --- band ratios ---
    if any(~cellfun(@isempty, regexp(varNames, '^ratio_', 'once')))
        parts{end+1} = 'ratios';
    end

    % --- spatial coordinates ---
    if any(ismember({'x_sinu','y_sinu'}, varNames))
        parts{end+1} = 'xy';
    end

    if isempty(parts)
        tag = 'custom';
    else
        tag = strjoin(parts, '_');
    end
end

% -------------------------------------------------------------------------
% Geo / DEM helpers
% -------------------------------------------------------------------------

function doy = localParseDoyFromTileToken(tileToken)
    % Extract DOY from MOD09GA tile token, e.g. "MOD09GA.A2019152.h17v02.061" -> 152
    tok = regexp(char(tileToken), 'A\d{4}(\d{3})', 'tokens', 'once');
    if isempty(tok)
        doy = 182;   % fall back to mid-year
    else
        doy = str2double(tok{1});
    end
end

function geoData = localLoadGeoData(geoMatPath)
    % Returns struct with fields elevation, slope, aspect (2400x2400 double).
    % Missing fields are filled with NaN arrays of that size.
    ny = 2400; nx = 2400;
    geoData = struct('elevation', nan(ny, nx), 'slope', nan(ny, nx), 'aspect', nan(ny, nx));

    if ~exist(geoMatPath, 'file')
        localLog(sprintf('WARNING: geo MAT file not found: %s — elevation/slope/aspect will be NaN.', geoMatPath));
        return;
    end

    try
        raw = load(geoMatPath);
    catch ME
        localLog(sprintf('WARNING: failed to load geo MAT (%s) — terrain features will be NaN.', ME.message));
        return;
    end

    % Resolve top-level geo struct (same logic as fill_spice_tile_dem_model)
    gs = localExtractGeoStruct(raw);
    if isempty(gs)
        localLog(sprintf('WARNING: no usable geo struct in %s — terrain features will be NaN.', geoMatPath));
        return;
    end

    elevField   = localFindGeoField(gs, {'elevation','elev','dem','DEM','z','height','alt','altitude'});
    slopeField  = localFindGeoField(gs, {'slope','Slope','SLOPE','gradient','grad'});
    aspectField = localFindGeoField(gs, {'aspect','Aspect','ASPECT','slope_aspect'});

    % Elevation (may be a nested struct with sub-fields z, a, s)
    if ~isempty(elevField)
        rawElev = gs.(elevField);
        if isstruct(rawElev)
            % Nested layout: e.g. geo.dem.z / geo.dem.a / geo.dem.s
            subZ = localFindGeoField(rawElev, {'z','elevation','elev','height','alt'});
            subS = localFindGeoField(rawElev, {'s','slope','Slope','SLOPE','gradient'});
            subA = localFindGeoField(rawElev, {'a','aspect','Aspect','ASPECT','slope_aspect'});
            if ~isempty(subZ)
                geoData.elevation = localResizeGeoArray(double(rawElev.(subZ)), ny, nx);
            end
            if ~isempty(subS) && isempty(slopeField)
                geoData.slope = localResizeGeoArray(double(rawElev.(subS)), ny, nx);
            end
            if ~isempty(subA) && isempty(aspectField)
                geoData.aspect = localResizeGeoArray(double(rawElev.(subA)), ny, nx);
            end
        else
            geoData.elevation = localResizeGeoArray(double(rawElev), ny, nx);
        end
    end

    if ~isempty(slopeField) && ~isstruct(gs.(slopeField))
        geoData.slope = localResizeGeoArray(double(gs.(slopeField)), ny, nx);
    end
    if ~isempty(aspectField) && ~isstruct(gs.(aspectField))
        geoData.aspect = localResizeGeoArray(double(gs.(aspectField)), ny, nx);
    end

    % Derive slope from elevation if no slope field was found in the mat file.
    % Uses central-difference gradient with the MODIS 500m pixel size (463.3 m).
    if ~any(isfinite(geoData.slope(:))) && any(isfinite(geoData.elevation(:)))
        localLog('  No slope field found — deriving slope from elevation grid (MODIS 463.3 m pixels).');
        modisPixelSize = 463.312716527778;
        [dzdx, dzdy] = gradient(geoData.elevation, modisPixelSize);
        geoData.slope = atand(sqrt(dzdx.^2 + dzdy.^2));
    end
end

function gs = localExtractGeoStruct(raw)
    gs = [];
    if isfield(raw, 'geo') && isstruct(raw.geo)
        gs = raw.geo; return;
    end
    f = fieldnames(raw);
    for i = 1:numel(f)
        if isstruct(raw.(f{i}))
            gs = raw.(f{i}); return;
        end
    end
    if isfield(raw,'lat') || isfield(raw,'elevation') || isfield(raw,'elev')
        gs = raw;
    end
end

function fname = localFindGeoField(s, candidates)
    fname = '';
    for i = 1:numel(candidates)
        if isfield(s, candidates{i})
            fname = candidates{i}; return;
        end
    end
end

function arr = localResizeGeoArray(arr, ny, nx)
    if isequal(size(arr), [ny, nx]); return; end
    if isequal(size(arr), [nx, ny]); arr = arr'; return; end
    warning('Geo array size %s does not match expected %dx%d; using as-is.', mat2str(size(arr)), ny, nx);
end

function p = localDefaultGeoMatPath()
    pathLinux   = '/data/git/let-it-snow-2/geo/geo_let_it_snow.mat';
    pathWindows = '\\lv-reikni-01.lv.is\data\git\let-it-snow-2\geo\geo_let_it_snow.mat';
    if ispc(); preferred = {pathWindows, pathLinux};
    else;       preferred = {pathLinux, pathWindows};
    end
    p = preferred{1};
    for i = 1:numel(preferred)
        if exist(preferred{i}, 'file'); p = preferred{i}; return; end
    end
end