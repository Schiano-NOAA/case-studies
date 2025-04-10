#' Convert SS3 data into format required by FIMS (works for petrale and opaka so far)
#'
#' Uses output from `r4ss::SS_read()` or `r4ss::SS_readdat()` and does
#' filtering, simplifying, and reformatting.
#'
#' @param dat The `dat` element of the list created by `r4ss::SS_read()` or the 
#' output from running `r4ss::SS_readdat()` directly.
#' @param fleets Which fleets to include in the processed output.
#' @param ages Vector of ages to index.
#' @param lengths Vector of lengths to index.
#' @return A data frame that can be passed to `FIMS::FIMSFrame()`
#' @author Ian G. Taylor, Megumi Oshima
#' @export

get_ss3_data <- function(dat, fleets, ages, lengths) {
  # create empty data frame
  res <- data.frame(
    type = character(),
    name = character(),
    age = integer(),
    length = integer(),
    datestart = character(),
    dateend = character(),
    value = double(),
    unit = character(),
    uncertainty = double()
  )

  # Q: is it true that we can only have a single landings fleet? 
  #    m_landings() doesn't accept a fleet name.
  # Meg comment: I modified the catch to give from all `fleets` and can index them like in SEFSC scamp case study example for now.

  # aggregate landings across fleets
  catch_by_year_fleet <- dat$catch |>
    #dplyr::group_by(year) |>
    #dplyr::summarize(catch = sum(catch), uncertainty = mean(catch_se)) |> 
    dplyr::filter(year != -999)  |> 
    dplyr::filter(fleet %in% fleets)

  # convert landings to FIMSFrame format
  landings <- data.frame(
    type = "landings",
    name = paste0("fleet", catch_by_year_fleet$fleet), # landings aggregated to fleet 1
    age = NA,
    length = NA, 
    datestart = paste0(catch_by_year_fleet$year, "-01-01"),
    dateend = paste0(catch_by_year_fleet$year, "-12-31"),
    value = catch_by_year_fleet$catch,
    unit = "mt",
    uncertainty = catch_by_year_fleet$catch_se
  )

  # check for any gaps in landings time series
  years <- min(catch_by_year_fleet$year):max(catch_by_year_fleet$year)
  if (!all(years %in% catch_by_year_fleet$year)) {
    stop("missing years in landings")
  }

  # convert indices to FIMSFrame format
  index_info <- dat$CPUE |>
    dplyr::filter(index %in% fleets) |>
    dplyr::select(year, index, obs, se_log)

  # add -999 for missing years
  # create empty data frame for all combinations of year and fleet
  index_info_empty <- tidyr::expand_grid(
    year = years,
    index = fleets
  ) |> dplyr::mutate(obs = -999, se_log = 1)
  # combine the two data frames and remove redundant rows
  index_info <- rbind(index_info, index_info_empty) |>
    dplyr::distinct(year, index, .keep_all = TRUE) |>
    dplyr::arrange(index, year)

  indices <- data.frame(
    type = "index",
    name = paste0("fleet", index_info$index),
    age = NA,
    length = NA, 
    datestart = paste0(index_info$year, "-01-01"),
    dateend = paste0(index_info$year, "-12-31"),
    value = index_info$obs,
    unit = "",
    uncertainty = index_info$se_log
  )

  if(!is.null(dat$agecomp)){

  # partially convert age comps (filter, make into long table)

  # first rescale females to sum to 1.0
  # (data processing step had females + males sum to 100 for no good reason)
  dat$agecomp$sum_fem <-
    dat$agecomp |>
    dplyr::select(dplyr::starts_with(c("f","a"), ignore.case = FALSE) ) |> # get female comps (or comps if single-sex)
    rowSums()
  # couldn't figure out dplyr approach to rescaling the subset of columns
  # with female proportions to sum to 1.0
 fcols <- dat$agecomp  |> dplyr::select(dplyr::starts_with("f", ignore.case = FALSE))
  if(length(fcols) > 0){
    dat$agecomp[, names(dat$agecomp) %in% paste0("f", ages)] <-
    dat$agecomp[, names(dat$agecomp) %in% paste0("f", ages)] /
      dat$agecomp$sum_fem
  }else{
    dat$agecomp[, names(dat$agecomp) %in% paste0("a", ages)] <-
    dat$agecomp[, names(dat$agecomp) %in% paste0("a", ages)] /
      dat$agecomp$sum_fem
  }

  # further processing
  age_info <-
    dat$agecomp |>
    dplyr::filter(fleet %in% fleets) |> # filter by requested fleets
    dplyr::mutate(fleet = abs(fleet)) |> # convert any negative fleet to positive
    dplyr::select(!dplyr::matches("^m[0-9]")) |> # exclude male comps
    tidyr::pivot_longer( # convert columns f1...f17 to values in a new "age" colum of a longer table
      cols = dplyr::matches("^f[0-9]") | dplyr::matches("^a[0-9]"), # 2-sex model uses f1, f2, ...; 1-sex model uses a1, a2, ...
      names_to = "age",
      values_to = "value"
    ) |>
    dplyr::mutate(age = as.numeric(substring(age, first = 2))) |> # convert "f17" to 17
    dplyr::select(year, fleet, Nsamp, age, value)

  # add -999 for missing years
  # create empty data frame for all combinations of year, fleet, and age
  age_info_empty <- tidyr::expand_grid(
    year = years,
    fleet = fleets,
    age = ages
  ) |> dplyr::mutate(Nsamp = 1, value = -999 - 0.001)
  # combine the two data frames and remove redundant rows
  # NOTE: this removes some age comp data because there
  # were years with multiple observations from the same fleet
  # due to multiple ageing error matrices
  age_info <- rbind(age_info, age_info_empty) |>
    dplyr::distinct(year, fleet, age, .keep_all = TRUE) |>
    dplyr::arrange(fleet, year, age)

  # finish converting age comps to FIMSFrame format
  agecomps <- data.frame(
    type = "age",
    name = paste0("fleet", abs(age_info$fleet)), # abs to include fleet == -4
    age = age_info$age,
    length = NA, 
    datestart = paste0(age_info$year, "-01-01"),
    dateend = paste0(age_info$year, "-12-31"),
    value = age_info$value + 0.001, # add constant to avoid 0 values
    unit = "",
    # Q: should uncertainty here be the total sample size across bins, or the samples within the bin?
    # uncertainty = round(age_info$Nsamp * age_info$value)
    uncertainty = round(age_info$Nsamp)
  )
  }else{
    agecomps <- NULL
  }
  
## Length composition data

  if(!is.null(dat[['lencomp']])){

    #leaving out the re-scaling part for females to 1
    len_info <-
    dat$lencomp |>
    dplyr::filter(fleet %in% fleets) |> # filter by requested fleets
    dplyr::mutate(fleet = abs(fleet)) |> # convert any negative fleet to positive
    dplyr::select(!dplyr::matches("^m[0-9]")) |> # exclude male comps
    tidyr::pivot_longer( # convert columns f1...f17 to values in a new "length" colum of a longer table
      cols = dplyr::matches("^f[0-9]") | dplyr::matches("^l[0-9]"), # 2-sex model uses f1, f2, ...; 1-sex model uses a1, a2, ...
      names_to = "length",
      values_to = "value"
    ) |>
    dplyr::mutate(length = as.numeric(substring(length, first = 2))) |> # convert "l17" to 17
    dplyr::select(year, fleet, Nsamp, length, value)

  # add -999 for missing years
  # create empty data frame for all combinations of year, fleet, and length
  len_info_empty <- tidyr::expand_grid(
    year = years,
    fleet = fleets,
    length = lengths
  ) |> dplyr::mutate(Nsamp = 1, value = -999 - 0.001)
  # combine the two data frames and remove redundant rows
  len_info <- rbind(len_info, len_info_empty) |>
    dplyr::distinct(year, fleet, length, .keep_all = TRUE) |>
    dplyr::arrange(fleet, year, length)

  # finish converting age comps to FIMSFrame format
  lencomps <- data.frame(
    type = "length", #will likely need to change name 
    name = paste0("fleet", abs(len_info$fleet)), # abs to include fleet == -4
    age = NA,
    length = len_info$length,
    datestart = paste0(len_info$year, "-01-01"),
    dateend = paste0(len_info$year, "-12-31"),
    value = len_info$value + 0.001, # add constant to avoid 0 values
    unit = "",
    # Q: should uncertainty here be the total sample size across bins, or the samples within the bin?
    # uncertainty = round(len_info$Nsamp * len_info$value)
    uncertainty = round(len_info$Nsamp)
  )

  }else{
    lencomps <- NULL #not sure if we need this but wanting to avoid an error if missing age or length comps
  }


  # combine all data sources
  res <- rbind(res, landings, indices, agecomps, lencomps)
}
