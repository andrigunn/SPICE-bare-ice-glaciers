function ncPath = get_spice_netcdf_path_by_date(dateIn, varargin)
%GET_SPICE_NETCDF_PATH_BY_DATE Return SPICE MOD09GA NetCDF path for a date.
%   NCPATH = GET_SPICE_NETCDF_PATH_BY_DATE(DATEIN) returns the file path for
%   DATEIN in the default SPICE folder and default tile h17v02.
%
%   DATEIN can be:
%     - datetime (scalar)
%     - date string like '2025-04-01'
%
%   Name-value options:
%     'SpiceDir'   Folder containing SPICE NetCDF files
%                  (default platform path)
%     'TileId'     MODIS tile id, default 'h17v02'
%     'MustExist'  If true (default), error when file is not found.
%                  If false, return constructed expected path.
%
%   Example:
%     p = get_spice_netcdf_path_by_date('2025-04-01');
%
%     p = get_spice_netcdf_path_by_date(datetime(2025,4,1), ...
%         'TileId', 'h17v02');

    p = inputParser;
    p.addRequired('dateIn', @(x) isdatetime(x) || ischar(x) || isstring(x));
    p.addParameter('SpiceDir', localDefaultSpiceDir(), @(x) ischar(x) || isstring(x));
    p.addParameter('TileId', 'h17v02', @(x) ischar(x) || isstring(x));
    p.addParameter('MustExist', true, @(x) islogical(x) || isnumeric(x));
    p.parse(dateIn, varargin{:});
    args = p.Results;

    dt = localParseDate(args.dateIn);
    spiceDir = char(args.SpiceDir);
    tileId = lower(strtrim(char(args.TileId)));
    mustExist = logical(args.MustExist);

    yyyy = year(dt);
    doy = day(dt, 'dayofyear');

    if ~exist(spiceDir, 'dir')
        error('SPICE directory not found: %s', spiceDir);
    end

    % Flexible search to allow future collection versions beyond 061.
    pattern = sprintf('SPICE_MOD09GA.A%04d%03d.%s.*.nc', yyyy, doy, tileId);
    matches = dir(fullfile(spiceDir, pattern));

    if ~isempty(matches)
        [~, idx] = sort({matches.name});
        best = matches(idx(end));
        ncPath = fullfile(best.folder, best.name);
        return;
    end

    % Construct canonical expected path with collection 061.
    ncPath = fullfile(spiceDir, sprintf('SPICE_MOD09GA.A%04d%03d.%s.061.nc', yyyy, doy, tileId));

    if mustExist
        dateText = char(string(dt, 'yyyy-MM-dd'));
        error('No SPICE NetCDF file found for %s (tile %s) in %s', ...
            dateText, tileId, spiceDir);
    end
end

function dt = localParseDate(dateIn)
    if isdatetime(dateIn)
        if ~isscalar(dateIn)
            error('dateIn must be a scalar datetime.');
        end
        dt = dateIn;
        return;
    end

    s = char(string(dateIn));
    try
        dt = datetime(s, 'InputFormat', 'yyyy-MM-dd');
    catch
        dt = datetime(s);
    end

    if ~isscalar(dt) || isnat(dt)
        error('Could not parse dateIn. Use datetime or a string like yyyy-MM-dd.');
    end
end

function p = localDefaultSpiceDir()
    if ispc()
        p = '\\lv-reikni-01.lv.is\data\SPICE\mod09ga';
    else
        p = '/data/SPICE/mod09ga';
    end
end
