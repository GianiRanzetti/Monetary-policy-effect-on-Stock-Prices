% This script replicates the results in:
% Jarocinski, Karadi, Deconstructing Monetary Policy Surprises - The Role 
% of Information Shocks, forthcoming ain the AEJ:Macroeconomics.
%
% The script estimates a monthly VAR with high-frequency monetary policy
% surprises and identifies shocks with sign restrictions.
% The different results in the paper can be obtained by uncommenting the
% appropriate lines.
clear all, close all

% SAMPLE AND DATA: spl, modname, addvar
spl = [1992 1; 2024 1];


modname = 'us1'; %'us1','ea1','us2','ea2'
addvar = '';

% IDENTIFICATION: idscheme, mnames
idscheme = 'sgnm2'; %'chol','sgnm2','sgnm2strg','supdem'

mnames = {'ff4_hf','sp500_hf'}; % US baseline

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% PRIOR
prior.lags = 12;
prior.minnesota.tightness = .2;
prior.minnesota.decay = 1;
prior.Nm = length(mnames);

% create the output folder based on the calling filename
st = dbstack; pathout = st(end).name; clear st 
mkdir(pathout)
pathout = [pathout '/'];

% functions for time operations
ym2t = @(x) x(1)+x(2)/12 - 1/24; % convert [year month] into time
t2datestr = @(t) [num2str(floor(t)) char(repmat(109,length(t),1)) num2str(12*(t-floor(t)+1/24),'%02.0f')];
t2ym = @(t) [floor(t) round(12*(t-floor(t)+1/24))]; % convert time into [year month]
ymdif = @(x1,x2) (x2(1)-x1(1))*12+x2(2)-x1(2);
findym = @(x,t) find(abs(t-ym2t(x))<1e-6); % find [year month] in time vector t

% Gibbs sampler settings
gssettings.ndraws = 400;
gssettings.burnin = 400;
gssettings.saveevery = 4;
gssettings.computemarglik = 0;

% detect poorman shocks and if yes override the identification to choleski
if (~isempty(strfind(mnames{1},'neg')) && ~isempty(strfind(mnames{2},'pos')))
    idscheme = 'chol';
end

% nice names
mdict = {'ff4_', '  surprise in\newline3m ff futures';
         'sp500_', 'surprise in\newlineS&P500'};
mnames_nice = applydictregexp(mnames, mdict);
mylimits = nan(length(mnames),2);

% define y
ny1 = 5;
switch modname
    case 'us1'
        ynames = {'gs1','logsp500','us_rgdp','us_gdpdef','ebpnew'};
    otherwise
        disp(modname), error('unknown modname');
end

if ~isempty(addvar)
    try
        findstrings(addvar,ynames);
    catch
        ynames = [ynames {addvar}]; modname = [modname '_' addvar];
    end
end

% nice_names, yylimits, nonst
dictfname = '/Users/gianiranzetti/Github/Monetary-policy-effect-on-Stock-Prices/data/ydict.csv';
fileID = fopen(dictfname);
ydict = textscan(fileID,'%s %q %d %f %f','Delimiter',',','HeaderLines',1);
fclose(fileID);
ynames_nice = applydict(ynames, [ydict{1} ydict{2}]);%ynames_nice = ynames;
yylimits = [ydict{4} ydict{5}];
yylimits = yylimits(findstrings(ynames,ydict{1}),:);
nonst = ydict{3};
nonst = nonst(findstrings(ynames,ydict{1}),:);

% load data
datafname = '/Users/gianiranzetti/Github/Monetary-policy-effect-on-Stock-Prices/data/VARdata.csv';
data.Nm = length(mnames);
data.names = [mnames ynames];
d = importdata(datafname); dat = d.data; txt = d.colheaders;
tbeg = find(dat(:,1)==spl(1,1) & dat(:,2)==spl(1,2)); if isempty(tbeg), tbeg=1; end
tend = find(dat(:,1)==spl(2,1) & dat(:,2)==spl(2,2)); if isempty(tend), tend=size(dat,1); end
ysel = findstrings(data.names, txt(1,:));
data.y = dat(tbeg:tend, ysel);
data.w = ones(size(data.y,1),1);
data.time = linspace(ym2t(dat(tbeg,1:2)), ym2t(dat(tend,1:2)), size(data.y,1))';
clear d dat txt tbeg tend ysel

% check ydata for missing values, determine the sample
datatemp = checkdata(data, t2datestr, 1:data.Nm);
idspl = [t2datestr(datatemp.time(1)) '-' t2datestr(datatemp.time(end))];
clear datatemp

% output file names
fname = [pathout modname '_' strjoin(mnames,'_') '_' idspl '_' idscheme];
diary([fname '.txt'])
data = checkdata(data, t2datestr, 1:data.Nm); % again, for the diary
plot_y;

% print the correlation matrix of m
table = corr(data.y(:,1:data.Nm),'rows','pairwise');
in.cnames = strvcat(mnames);
in.rnames = strvcat(['correl.:' mnames]);
in.width = 200;
mprint(table,in)

% complete the minnesota prior
prior.minnesota.mvector = [zeros(data.Nm,1); nonst];

% replace NaNs with zeros in the initial condition
temp = data.y(1:prior.lags,:); temp(isnan(temp)) = 0; data.y(1:prior.lags,:) = temp; 

% drop the shocks before February 1994
id = data.time<ym2t([1994 2])-1e-6; data.y(id,1:data.Nm) = NaN;

% estimate the VAR
%data.y(isnan(data.y)) = 0; res = VAR_dummyobsprior(data.y,data.w,gssettings.ndraws,prior);
res = VAR_withiid1kf(data, prior, gssettings);

savedata([fname '_data.csv'], data, t2ym)
%% identification
MAlags = 36;
N = length(data.names);

switch idscheme
    case 'chol'
        shocknames = data.names;
        irfs_draws = NaN(N,N,MAlags,gssettings.ndraws);
        for i = 1:gssettings.ndraws
            betadraw = res.beta_draws(1:end-size(data.w,2),:,i);
            sigmadraw = res.sigma_draws(:,:,i);
            response = impulsdtrf(reshape(betadraw',N,N,prior.lags), chol(sigmadraw), MAlags);
            irfs_draws(:,:,:,i) = response;
        end
        ss = 1;
        if length(mnames)>1 && ((~isempty(strfind(mnames{1},'neg')) && ~isempty(strfind(mnames{2},'pos'))) || ~isempty(strfind(mnames{2},'_signrestr'))), ss = 1:2; end
    case 'sgnm2' % baseline two sign restrictions
        shocknames = [{'mon.pol.', 'CBinfo'} mnames(2+1:end) ynames];
        dims = {[1 2]};
        imonpol = 1; inews = 2;
        test_restr = @(irfs)... %% restrictions by shock (i.e. by column):
            irfs(1,imonpol,1) > 0 && irfs(2,imonpol,1) < 0 &&... % mp
            irfs(1,inews,1) > 0 && irfs(2,inews,1) > 0; % cbi
        b_normalize = ones(1,N);
        max_try = 1000;
        disp(test_restr)
        irfs_draws = resirfssign(res, MAlags, dims, test_restr, b_normalize, max_try);
        %[irfs_draws, irfs_l_draws, irfs_u_draws] = resirfssign_robust(res, MAlags, dims, test_restr, b_normalize, max_try);
        ss = 1:2;
end

%% reporting

% report variance decompositon
vdec_mean = table_vdecomp(irfs_draws, 1:N, ss, data.names, shocknames, 24);

% report the irfs:
qtoplot = [0.5 0.25 0.75 0.1 0.9]; % quantiles to plot
varnames = [mnames, ynames]; varnames_nice = [mnames_nice ynames_nice]; shocknames_nice = shocknames;
ylimits = [];
%ylimits = [mylimits; yylimits];
transf = nan(N,2);

% print out the impact responses
table_irf(irfs_draws, ss, 1, varnames, qtoplot(1:3));
table_irf(irfs_draws, ss, 1, varnames, qtoplot([1 4 5]));

% plot the irfs
hh = plot_irfs_draws(irfs_draws, data.Nm+1:min(N,data.Nm+ny1), ss, varnames_nice, varnames, shocknames_nice, idscheme, qtoplot, [0 0 1], '', ylimits, transf); align_Ylabels(hh); saveTightFigure(hh,[fname '_irfy1'],'pdf')
%hh = plot_irfs_draws(irfs_draws, data.Nm+ny1+1:min(N,data.Nm+2*ny1), ss, varnames_nice, varnames, shocknames_nice, idscheme, qtoplot, [0 0 1], '', ylimits); align_Ylabels(hh); saveTightFigure(hh,[fname '_irfy2'],'pdf')
%hh = plot_irfs_draws(irfs_draws, 1:N, ss, varnames_nice, varnames, shocknames_nice, idscheme, qtoplot, [0 0 1], '', ylimits); align_Ylabels(hh); saveTightFigure(hh,[fname '_irfmy'],'pdf')

if 0 % save the ylimits
    hh = plot_irfs_draws(irfs_draws, 1:N, ss, varnames_nice, varnames, shocknames_nice, idscheme, qtoplot, [0 0 1], '', ylimits, transf); align_Ylabels(hh);
    ylimits = cell2mat(get(hh.Children,'Ylim')); ylimits = ylimits(1:max(ss):N*max(ss),:); ylimits = flipud(ylimits);
    save([fname '_ylimits.mat'],'ylimits');
end

if ~isempty(addvar)
    ylimits = [mylimits; yylimits];
    varstoplot = findstrings(addvar,varnames);
    hh = plot_irfs_draws(irfs_draws, varstoplot, ss, varnames_nice, varnames, shocknames_nice, idscheme, qtoplot, [0 0 1], '', ylimits);
    saveTightFigure(hh,[fname '_addvar'],'pdf')
end

if exist('irfs_l_draws','var')
credibility = [0.68 0.9];
hh = plot_irfs_draws_robust(irfs_draws, irfs_l_draws, irfs_u_draws, data.Nm+1:min(N,data.Nm+ny1), ss, varnames_nice, shocknames_nice, credibility, [0 0 1]); align_Ylabels(hh); saveTightFigure(hh,[fname '_rirfy1'],'pdf')
hh = plot_irfs_draws_robust(irfs_draws, irfs_l_draws, irfs_u_draws, data.Nm+ny1+1:N, ss, varnames_nice, shocknames_nice, credibility, [0 0 1]); align_Ylabels(hh); saveTightFigure(hh,[fname '_rirfy2'],'pdf')
%hh = plot_irfs_draws_robust(irfs_draws, irfs_l_draws, irfs_u_draws, 5:6, ss, varnames_nice, shocknames_nice, idscheme, credibility, [1 0 1]); align_Ylabels(hh); saveTightFigure(hh,[fname '_rirfyipcpi'],'pdf')
end

diary off