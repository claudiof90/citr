#' Invoke RStudio addin to insert Markdown citations
#'
#' @param bib_file Character. Path to BibTeX-file. See details.
#'
#' @details The path to the BibTeX-file can be set in the global options and is set to
#'    \code{references.bib} when the package is loaded. Once the path is changed in the
#'    RStudio addin, the global option is updated.
#'
#'    If \code{insert_citation} is called while the focus is on a R Markdown document,
#'    which includes a YAML front matter with paths to one or more bibliography files,
#'    \code{bib_file} is ignored. Instead the file(s) from the YAML front matter are used.
#'
#'    The addin caches bibliographies to avoid unnecessary hard drive access. If
#'    the specified bibliography path or the file paths in the YAML header change the files
#'    are reloaded. To manually reload a bibliography at an unchanged location click the
#'    action link.
#'
#' @return Inserts selected Markdown citation(s) at currenct location.
#'
#' @examples
#' \dontrun{
#'  insert_citation(bib_file = "references.bib")
#' }
#'
#' @import miniUI
#' @import shiny
#' @import assertthat
#' @export

insert_citation <- function(bib_file = options("citr.bibliography_path")) {
  bib_file <- unlist(bib_file)
  assert_that(is.character(bib_file))

  # Get bibliography files from YAML front matter if available
  ## Let's hope this doesn't cause too much trouble; this is a lot more sofisticated in rmarkdown, but the functions are not exported.
  yaml_found <- FALSE
  yaml_bib_file <- NULL
  context <- rstudioapi::getActiveDocumentContext()
  yaml_delimiters <- grep("^(---|\\.\\.\\.)\\s*$", context$contents)

  if(length(yaml_delimiters) >= 2 &&
     (yaml_delimiters[2] - yaml_delimiters[1] > 1) &&
     grepl("^---\\s*$", context$contents[yaml_delimiters[1]])) {
    yaml_params <- yaml::yaml.load(paste(context$contents[(yaml_delimiters[1] + 1):(yaml_delimiters[2] - 1)], collapse = "\n"))

    yaml_found <- TRUE
    yaml_bib_file <- yaml_params$bibliography
    relative_paths <- !grepl("^\\/|~", yaml_bib_file)
    absolute_yaml_bib_file <- yaml_bib_file
    absolute_yaml_bib_file[relative_paths] <- paste(dirname(context$path), yaml_bib_file[relative_paths], sep = "/")

    # Reload if new bibliography paths are used
    if(!isTRUE(all.equal(absolute_yaml_bib_file, options("citr.bibliography_path")[[1]]))) {
      options(citr.bibliography_path = absolute_yaml_bib_file)
      options(citr.bibliography_cache = NULL)
    }
  }

  ui <- miniPage(
    miniContentPanel(
      stableColumnLayout(
        selectizeInput(
          "selected_key"
          , choices = c(`BibTex file not found` = "")
          , label = ""
          , width = 700
          , multiple = TRUE
        )
      ),
      verbatimTextOutput("rendered_key"),
      stableColumnLayout(
        checkboxInput("in_paren", "In parentheses", value = TRUE),
        div(
          align = "right"
          , miniTitleBarButton("done", "  Insert citation  ", primary = TRUE)
          , miniTitleBarCancelButton()
        )
      ),
      br(),
      if(!yaml_found || is.null(yaml_bib_file)) {
        div(
          textInput("bib_file", "Path to BibTeX file:", value = bib_file, width = 700),
          helpText(
            "YAML front matter missing or no bibliography file(s) specified."
            , actionLink("discard_cache", "Reload bibliography")
          )
        )
      } else {
        div(
          helpText(
            "Bibliography file(s) found in YAML front matter:"
            , code(paste(yaml_bib_file, collapse = ", "))
          ),
          actionLink("discard_cache", "Reload bibliography file(s)")
        )
      }
    )
  )

  server <- function(input, output, session) {

    # Discard cache reactive
    reactive_variables <- reactiveValues(reload_bib = "init") # Set initial value
    observeEvent(input$discard_cache, {
      options(citr.bibliography_cache = NULL)
      reactive_variables$reload_bib <- paste0(sample(letters, 100, replace = TRUE), collapse = "") # Do stuff to trigger reload_bib reactive
    })
    reload_bib <- reactive({reactive_variables$reload_bib})

    # Load bibliography
    bibliography <- reactive({
      trigger <- reload_bib() # Triggers reactive when event link is clicked

      # cat(input$bib_file)
      # cat(options("citr.bibliography_path")[[1]])
      if(!is.null(input$bib_file) && !isTRUE(all.equal(input$bib_file, options("citr.bibliography_path")[[1]]))) {
        # cat("Discarding cache...\n")
        options(citr.bibliography_path = input$bib_file)
        options(citr.bibliography_cache = NULL)
      }

      # Use cached bibliography, if available
      if(
        is.null(options("citr.bibliography_cache")[[1]]) ||
        (yaml_found && !is.null(yaml_bib_file) && !isTRUE(all.equal(absolute_yaml_bib_file, options("citr.bibliography_path")[[1]])))
      ) {
        # cat("Reloading ...\n")
        if(!yaml_found || is.null(yaml_bib_file)) { # Use specified bibliography

          current_bib <- tryCatch(RefManageR::ReadBib(file = input$bib_file), error = function(e) NULL)
        } else if(yaml_found & !is.null(yaml_bib_file)) { # Use YAML bibliography, if available

          if(length(yaml_bib_file) == 1) {
            current_bib <- tryCatch(RefManageR::ReadBib(file = absolute_yaml_bib_file), error = function(e) NULL)
          } else {
            bibs <- lapply(absolute_yaml_bib_file, function(file) tryCatch(RefManageR::ReadBib(file), error = function(e) NULL))

            ## Merge if multiple bib files were imported succesfully
            not_found <- sapply(bibs, is.null)
            if(any(not_found)) warning("Unable to read bibliography file(s) ", paste(paste0("'", yaml_bib_file[not_found], "'"), collapse = ", "))
            current_bib <- do.call(c, bibs[!not_found])
          }
          options(citr.bibliography_path = absolute_yaml_bib_file)
        }

        ## Cache bibliography
        options(citr.bibliography_cache = current_bib)
      } else {
        current_bib <- options("citr.bibliography_cache")[[1]]
      }

      current_bib
    })

    ## Update items in selection list
    observe({
      citation_keys <- names(bibliography())

      if(length(citation_keys > 0)) {
        names(citation_keys) <- paste_references(bibliography())

        updateSelectInput(session, "selected_key", choices = c(`Search terms` = "", citation_keys), label = "")
      } else {
        updateSelectInput(session, "selected_key", c(`BibTex file not found` = ""), label = "")
      }
    })

    # Create citation based on current selection
    current_key <- reactive({paste_citation_keys(input$selected_key, input$in_paren)})
    output$rendered_key <- renderText({if(!is.null(current_key())) current_key() else "No reference selected."})

    # Insert citation when button is clicked
    observeEvent(
      input$done
      , {
        if(!(current_key() %in% c("[@]", "@"))) rstudioapi::insertText(current_key())
        invisible(stopApp())
      }
    )
  }

  viewer <- dialogViewer("Insert citation", width = 600, height = 500)
  runGadget(ui, server, viewer = viewer)
}


stableColumnLayout <- function(...) {
  dots <- list(...)
  n <- length(dots)
  width <- 12 / n
  class <- sprintf("col-xs-%s col-md-%s", width, width)
  fluidRow(
    lapply(dots, function(el) {
      div(class = class, el)
    })
  )
}