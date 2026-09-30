# SPICE: Spectrally Classified Surfaces for Glaciers in Iceland (2000–2025)

<img width="2816" height="1536" alt="overview" src="https://github.com/user-attachments/assets/d5a00e51-6630-448a-8a87-3164626451e0" />

This repository contains the processing code, machine learning models, and the tools to make the SPICE dataset. developed for the manuscript "2026-09-22-spectral-glaciers-manucript-rev-clean.docx"[cite: 1]. The project provides a continuous 26-year daily satellite record (2000–2025) of surface albedo, snowline dynamics, and bare-ice exposure across Icelandic ice caps[cite: 1].

## Overview

Icelandic glacier melt is heavily driven by summer ablation, which is amplified when impurity-rich, dark bare ice is exposed, dropping surface albedo to as low as 5% to 10%[cite: 1]. Tracking this rapid spatial and temporal evolution is notoriously difficult due to Iceland's persistent cloud cover[cite: 1]. This project utilizes MODIS imagery and a two-stage machine learning gap-filling pipeline to overcome these observational challenges, providing a gap-free daily classification of glacier surfaces to aid in glaciological hydrology forecasting[cite: 1].

## Dataset Features

* **Surface Classification:** Categorizes glacier pixels into three distinct classes: clean snow, bare glacier ice, and contaminated/dirty snow[cite: 1].
* **High-Accuracy ML Model:** Utilizes a MATLAB (R2026a) fine decision tree (105 nodes) trained on 13 features (MODIS spectral bands 1–6, temporal data, and terrain metrics), achieving 99.96% cross-validation accuracy[cite: 1].
* **Robust Gap-Filling:** Employs a ±3-day temporal merge followed by a localized terrain-based gap-filling model to achieve 100% data availability over glaciated areas during the melt season (April–September)[cite: 1].
* **Snowline Altitude (SLA) Tracking:** Includes algorithms to calculate end-of-season snowlines by slicing glaciers into 25 m elevation bands and interpolating the 50% bare-ice crossover point[cite: 1].

## Prerequisites and Data Sources

To run the pipeline from scratch, the following datasets are required:
* **MOD09GA (Collection 6.1):** Daily surface reflectance imagery (Tile h17v02, 463 m spatial resolution) accessed via NASA Earthdata[cite: 1].
* **MOD10A1 (Collection 6.1):** Daily NDSI snow cover product used for initial cloud masking[cite: 1].
* **ÍslandsDEM v1.0:** Digital Elevation Model used for extracting geospatial predictors (elevation, slope, aspect) reprojected to the MODIS sinusoidal grid[cite: 1].
* **Glacier Outlines:** Boundaries from 2003, 2019, or 2025 used to restrict classification strictly to ice-covered pixels[cite: 1].

## Processing Pipeline

1. **Preprocessing & Masking:** Glacier and cloud masks are applied to the daily MODIS tiles before classification[cite: 1].
2. **Daily Classification:** The primary decision tree model predicts the surface class for all valid, clear-sky pixels[cite: 1].
3. **Temporal Merge:** Unclassified, cloud-obscured pixels are gap-filled by reading the classification field from neighboring tiles within a ±3-day window[cite: 1].
4. **Local Gap Filling:** Persistently cloudy areas are filled using a per-tile secondary classification tree trained on the available classified pixels and local terrain predictors[cite: 1].
5. **Analysis & Hypsometry:** Extracted outputs include maximum annual bare-ice extent, ELA tracking, and ELA climate sensitivity assessments[cite: 1].

## Citation

If you utilize this code or the SPICE dataset in your research, please reference the corresponding manuscript:
> Gunnarsson, A., Sverrisdóttir, E. B., Pálsson, F., & Gardarsson, S. M. (2026). *Bare-Ice Dynamics on Icelandic Glaciers: Trends and Variability from Daily MODIS Observations (2000–2025), in press. [cite: 1].
