version 1.0

workflow donor_assign {
    input {
        File BAI
        File BAM
        Int num_splits
        File VCF
        File donor_list_file
    }
    call generate_regions {
        input:
            BAI = BAI, 
            BAM_PATH = "~{BAM}",
            num_splits = num_splits,
    }

    scatter (region in generate_regions.regions_list){
        call region_donor_log_likelihoods {
            input:
                BAI = BAI,
                BAM_PATH = "~{BAM}",
                region = region,
                VCF_PATH = "~{VCF}",
                donor_list_file = donor_list_file
        }
    }

    call gather_region_donor_log_likelihoods{
        input:
            barcode_log_likelihood = region_donor_log_likelihoods.barcode_log_likelihood
    }

    output {
        Array[String] regions_list = generate_regions.regions_list
        Array[File] region_barcode_log_likelihood_list = region_donor_log_likelihoods.barcode_log_likelihood 
        File total_barcode_donor_likelihoods = gather_region_donor_log_likelihoods.total_barcode_donor_likelihoods
    }
}

task generate_regions {
    input {
        File BAI
        String BAM_PATH
        Int num_splits
        String docker_image = 'us.gcr.io/landerlab-atacseq-200218/donor_assign:0.15'
    }
    command {
        gsutil cat ${BAM_PATH} | samtools view -H > header.sam
        python3 /app/donor_assignment/split_regions.py header.sam ${BAI} ${num_splits} # for now, not going to pipe because we have other prints in there ## > list_of_regions.txt
        head -5 list_of_regions.txt > only_five_regions.txt
    }
    output {
        Array[String] regions_list = read_lines("only_five_regions.txt")
    }

    runtime {
        docker: docker_image
        cpu: 1
        memory: "16GB"
        preemptible: 1
    }
}

task region_donor_log_likelihoods {
    input {
        File BAI
        String BAM_PATH
        String region
        String VCF_PATH
        File donor_list_file
        String docker_image = 'us.gcr.io/landerlab-atacseq-200218/donor_assign:0.15'
    }

    command {
        set -ex
        /app/monitor_script.sh &
        ## from https://support.terra.bio/hc/en-us/community/posts/16214505476507-How-to-run-samtools-on-gs-object-directly-to-get-a-BAM-slice-fast-for-example-
        ## write the GCP token in a file
        gcloud auth print-access-token > token.txt
        ## point the HTS ENV variable to that file
        export HTS_AUTH_LOCATION="token.txt"
        # these should be fast, no need to worry about access token expiring
        samtools view -X -b -o region.bam ${BAM_PATH} ${BAI} ${region}
        bcftools view -O z -o region.vcf.gz ${VCF_PATH} ${region}
        ls -l region.bam region.vcf.gz
        python3 /app/donor_assignment/count_reads_on_variants.py region.bam region.vcf.gz
        python3 /app/donor_assignment/likelihood_per_region.py results.tsv.gz ${donor_list_file} region.vcf.gz ${region}
    }

    output {
      File barcode_log_likelihood = glob("barcode_log_likelihood_*.txt.gz")[0]
    }

    runtime {
        docker: docker_image
        cpu: 1
        memory: "32GB"
        preemptible: 1
    }
}


task gather_region_donor_log_likelihoods {
    input {
        Array[File] barcode_log_likelihood
        String docker_image = 'us.gcr.io/landerlab-atacseq-200218/donor_assign:0.15'
    }

    command {
        python3 <<CODE 
        import pandas as pd
        barcode_log_likelihood_list = [ln.strip() for ln in open("~{write_lines(barcode_log_likelihood)}")]

        log_likelihood_df = pd.read_table(barcode_log_likelihood_list[0], index_col=0)
        for file in barcode_log_likelihood_list[1:]:
            curr_log_likelihood_df = pd.read_table(file, index_col=0)
            log_likelihood_df = log_likelihood_df.add(curr_log_likelihood_df, fill_value=0)
            
        log_likelihood_df.to_csv('total_barcode_donor_likelihoods.txt.gz', sep="\t")
        CODE
    }

    output {
        File total_barcode_donor_likelihoods = 'total_barcode_donor_likelihoods.txt.gz'
    }

    runtime {
        docker: docker_image
        cpu: 1
        memory: "32GB"
        preemptible: 1
    }
}
