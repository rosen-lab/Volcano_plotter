library(shiny)
library(shinyjs)
library(ggplot2)
library(ggrepel)
library(svglite)
library(colourpicker)

options(shiny.maxRequestSize=20*1024^2)
shinyServer(function(input, output, session) {
  # Global variables
  values <- reactiveValues(ran = FALSE, num_genesets = 1, cond1 = NULL, cond2 = NULL, plot_type = "volcano_plot") 
  
  # Load input file into data()
  data <- reactive({
    # Disable run button in case a bad file is uploaded after a good one
    disable("run")
    
    infile <- input$file1
    
    if (is.null(infile))
      return(NULL)
    
    # Load input data
    data <- try(read.table(infile$datapath, header = TRUE, stringsAsFactors = FALSE), silent = TRUE)
    
    # Fail if the data could not be read
    if (!is.data.frame(data)) {
      showNotification("ERROR: Could not load input file, file must be able to be read by the R function read.table", duration = NULL, type = "error")
      return(NULL)
    }
    
    # Fail if the data does not have the needed columns
    for (name in c("genes", "logFC", "logCPM", "PValue", "FDR")) {
      if (! name %in% colnames(data)) {
        showNotification(sprintf("ERROR: Input file must have column named %s", name), duration = NULL, type = "error")
        return(NULL)
      }
    }
    
    # Reset values in case a new file is uploaded
    has_conds <- FALSE
    
    # Split UCSC id and gene symbol
    split_genes <- t(as.data.frame(strsplit(data$genes, "\\|")))
    data$UCSC_ID <- split_genes[, 1]
    data$Gene_Symbol <- split_genes[, 2]
    
    # Remove genes and reorder columns
    data$genes <- NULL
    data <- data[, c(ncol(data), ncol(data)-1, 1:(ncol(data)-2))]
    
    # Check if conditions are present
    if (any(grepl("^Cond1_", colnames(data))) && any(grepl("^Cond2_", colnames(data)))) {
      has_conds <- TRUE
      index1 = grep("^Cond1_", colnames(data))[1]
      index2 = grep("^Cond2_", colnames(data))[1]
      values$cond1 = substr(colnames(data)[index1], 7, 1e6)
      values$cond2 = substr(colnames(data)[index2], 7, 1e6)
      colnames(data)[index1] = values$cond1
      colnames(data)[index2] = values$cond2
    }
    
    # Enable run button
    enable("run")
    # Determine what plot types are allowed
    if (has_conds) {
      updateSelectInput(session, "plot_type", choices = list("Volcano plot" = 0, "MA plot" = 1, "Abundance plot" = 2))
    } else {
      updateSelectInput(session, "plot_type", choices = list("Volcano plot" = 0, "MA plot" = 1))
    }
    
    return(data)
  })
  
  # Save plot in different formats
  output$dl_svg <- downloadHandler(
    filename = function() {
      paste0(values$plot_type, ".svg")
    },
    content = function(file) {
      ggsave(file, make_plot(), device = "svg", width = 8, height = 8)
    }
  )
  output$dl_pdf <- downloadHandler(
    filename = function() {
      paste0(values$plot_type, ".pdf")
    },
    content = function(file) {
      ggsave(file, make_plot(), device = "pdf", width = 8, height = 8)
    }
  )
  output$dl_png <- downloadHandler(
    filename = function() {
      paste0(values$plot_type, ".png")
    },
    content = function(file) {
      ggsave(file, make_plot(), device = "png", width = 8, height = 8)
    }
  )
  
  # Save table in different formats
  output$dl_csv <- downloadHandler(
    filename = "significant_genes.csv",
    content = function(file) {
      write.csv(data()[filter(), ], file = file, row.names = FALSE)
    }
  )
  output$dl_tsv <- downloadHandler(
    filename = "significant_genes.tsv",
    content = function(file) {
      write.table(data()[filter(), ], file = file, row.names = FALSE, sep = "\t")
    }
  )
  
  # Add geneset
  observeEvent(input$add_geneset, {
    values$num_genesets <- values$num_genesets + 1
    container_id <- sprintf("geneset_container%d", values$num_genesets)
    gs_id <- sprintf("geneset%d", values$num_genesets)
    col_id <- sprintf("color%d", values$num_genesets)
    
    # Default colors
    if (values$num_genesets > 4) {
      color <- "black"
    } else {
      defaults <- c("#0000FF", "#FF7F00", "#008B00", "#9400D3")
      color <- defaults[values$num_genesets] 
    }
    
    # Add element
    insertUI(
      selector = "#change_geneset", where = "beforeBegin",
      ui =  fluidRow(id = container_id,
                     column(8, textInput(gs_id, label = NULL, width = "100%")),
                     column(4, colourInput(col_id, label=NULL, value = color, showColour = "background", palette = "limited"))
      )
    )
    enable("rm_geneset")
  })
  
  # Remove geneset
  observeEvent(input$rm_geneset, {
    # Don't do anything if there's only one geneset
    if (values$num_genesets <= 1) {
      return(NULL)
    }
    removeUI(selector = sprintf("#geneset_container%d", values$num_genesets))
    values$num_genesets <- values$num_genesets - 1
    if (values$num_genesets == 1) {
      disable("rm_geneset")
    }
  })
  
  # Render up/down regulated genes
  output$up_down <- renderUI({
    number_up <- nrow(data()[filter() & data()$logFC>0, ])
    number_down <- nrow(data()[filter() & data()$logFC<0, ])
    
    div(class = "panel panel-default",
        div(class = "panel-heading large-text", "Significant genes"),
        fluidRow(class = "large-text text-center",
                 column(4, 
                        span(class="glyphicon glyphicon-arrow-up", style = "color:blue"),
                        span(class="glyphicon glyphicon-arrow-down", style = "color:blue"),
                        paste0(number_up + number_down, " total")),
                 column(4, 
                        span(class="glyphicon glyphicon-arrow-up", style = "color:green"),
                        paste0(number_up, " up regulated")
                 ),
                 column(4, 
                        span(class="glyphicon glyphicon-arrow-down", style = "color:red"),
                        paste0(number_down, " down regulated")
                 )
        )
    )
  })
  
  # Determine significant genes
  filter <- eventReactive(input$run, {
    values$ran <- TRUE
    return(data()$FDR <= input$FDR & abs(data()$logFC) >= input$FC & data()$logCPM >= input$CPM)
  })
  
  get_colors <- eventReactive(input$run, {
    colors <- c()
    
    # Don't run if there are no genesets, does weird things if removed
    if (values$num_genesets <= 0) {
      return(c("grey", "red2"))
    }
    
    for (i in 1:values$num_genesets) {
      # Ignore genesets with no highlighted genes
      if (! i %in% highlight()) {
        next()
      }
      colors <- append(colors, input[[sprintf("color%d", i)]])
    }
    colors <- append(colors, c("grey", "red2"))

    return(colors)
  })
  
  #Update highlighted genes
  highlight <- eventReactive(input$run, {
    out <- rep(FALSE, nrow(data()))

    for (i in 1:values$num_genesets) {
      genes <- input[[sprintf("geneset%d", i)]]
      genes <- unlist(strsplit(genes, "(\\s)*,(\\s)*"))
      if (input$search_style == "exact") {
        genes <- toupper(genes)
        out[toupper(data()$Gene_Symbol) %in% genes] <- i
      } else {
        for (j in 1:length(genes)) {
          if (length(genes[j]) == 0) {
            next
          }
          found <- grepl(genes[j], data()$Gene_Symbol, ignore.case = TRUE, perl = TRUE)
          out[found] <- i
        }
      }
    }
    return(as.factor(out))
    
  })
  
  # Create the plot only when run button is pressed
  output$plot <- renderPlot({make_plot()})
  make_plot <- eventReactive(input$run, {
    df <- data()
    df$significant <- filter()
    df$highlight <- highlight()
    if (input$plot_type == 0) {
      p <- ggplot(df, aes(x = logFC, y = -log10(PValue), color = significant))
      values$plot_type <- "volcano_plot"
    } else if (input$plot_type == 1) {
      p <- ggplot(df, aes(x = logCPM, y = logFC , color = significant))
      values$plot_type <- "MA_plot"
    } else {
      p <- ggplot(df, aes_string(x = values$cond1, y = values$cond2, color = "significant")) + 
        xlab(paste0("logCPM in ", values$cond1)) + ylab(paste0("logCPM in ", values$cond2))
      values$plot_type <- "abundance_plot"
    }
    p <- p + geom_point()
    p <- p + geom_point(data=df[df$highlight != 0, ], aes(color=highlight), size = 5)
    p <- p + geom_label_repel(data=df[df$highlight != 0, ], aes(label=Gene_Symbol, color=highlight), size = 5)
    p <- p + theme_bw(base_size = 16) + scale_color_manual(values = get_colors()) + guides(color = FALSE)
    
    # Enable download buttons
    enable("dl_svg")
    enable("dl_pdf")
    enable("dl_png")
    enable("dl_csv")
    enable("dl_tsv")
    
    return(p)
  })
  
  # Create the table
  output$data_table <- renderDataTable(data()[filter(), ])
      
})