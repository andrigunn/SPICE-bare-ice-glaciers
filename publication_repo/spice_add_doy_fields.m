function S = spice_add_doy_fields(S)
%SPICE_ADD_DOY_FIELDS Add day-of-year fields to a SPICE seasonal analysis struct.
%   S = SPICE_ADD_DOY_FIELDS(S) reads S.bareIceOnsetDateYMD and
%   S.fallSnowOnsetDateYMD (int32 YYYYMMDD, 0 = no onset) and adds:
%     S.bareIceOnsetDOY   same size, double, day-of-year (1-366), 0 = none
%     S.fallSnowOnsetDOY  same size, double, day-of-year (1-366), 0 = none
%
%   Conversion is fully vectorized using arithmetic only (no datetime calls),
%   so it runs in seconds even on 2400x2400xN stacks.
%
%   Example:
%     S = spice_add_doy_fields(S);
%     doy2018 = S.bareIceOnsetDOY(:,:, S.years==2018);

    if isfield(S, 'bareIceOnsetDateYMD')
        S.bareIceOnsetDOY = localYmdToDoy(S.bareIceOnsetDateYMD);
    end
    if isfield(S, 'fallSnowOnsetDateYMD')
        S.fallSnowOnsetDOY = localYmdToDoy(S.fallSnowOnsetDateYMD);
    end
end

function doy = localYmdToDoy(ymd)
    % Vectorized YYYYMMDD int32 -> day-of-year double.
    % 0 inputs produce 0 outputs. Handles leap years correctly.

    v = double(ymd);
    doy = zeros(size(v));
    mask = v > 0;
    if ~any(mask(:))
        return;
    end

    vm = double(v(mask));
    vm = vm(:);                         % ensure column vector
    y  = floor(vm / 10000);
    mo = floor(mod(vm, 10000) / 100);
    d  = mod(vm, 100);

    % Cumulative days before each month (non-leap year).
    cumDays = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334];

    baseDoy = cumDays(mo)' + d;         % cumDays(mo) may be row; transpose to column

    % Add 1 for months after February in leap years.
    isLeap = (mod(y, 4) == 0 & mod(y, 100) ~= 0) | (mod(y, 400) == 0);
    baseDoy(isLeap & mo > 2) = baseDoy(isLeap & mo > 2) + 1;

    doy(mask) = baseDoy;
end
